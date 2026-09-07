use FindBin;
use lib "$FindBin::Bin";
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../thirdparty/lib/perl5";
use strict;
use warnings;
use Mojo::Base -strict, -signatures;

use FakeAPI;
use Mojo::IOLoop;
use Mojo::IOLoop::Server;
use Mojo::Log;
use Mojo::Promise;
use RawSMTPClient;
use RecordingSMTPServer;
use SMTPProxy;
use Test::More;

plan tests => 18;

my $TEST_HOST = '127.0.0.1';
my $TEST_LOG = Mojo::Log->new(level => $ENV{TEST_LOG_LEVEL} // 'warn');

my $testApi = FakeAPI->new(result => { allow => 1, headers => [] });

# An upstream that supports DSN, and one that does not, each behind its own
# proxy so a single run can exercise both policies.
my $dsnUpstream = RecordingSMTPServer->new(
    port => Mojo::IOLoop::Server->generate_port,
    extensions => ['PIPELINING', 'DSN'],
);
my $plainUpstream = RecordingSMTPServer->new(
    port => Mojo::IOLoop::Server->generate_port,
    extensions => ['PIPELINING'],
);

my $DSN_PROXY_PORT = Mojo::IOLoop::Server->generate_port;
my $PLAIN_PROXY_PORT = Mojo::IOLoop::Server->generate_port;

sub setupProxy ($listenPort, $upstream) {
    SMTPProxy->new(
        log => $TEST_LOG,
        listen => [$TEST_HOST . ':' . $listenPort],
        tohost => $TEST_HOST,
        toport => $upstream->port,
        tls_cert => "$FindBin::Bin/certs-and-keys/server.crt",
        tls_key => "$FindBin::Bin/certs-and-keys/server.key",
        api => $testApi,
        service_name => 'smtp.proxy.service',
    )->setup;
}

# Drives one full session through the proxy, returning a promise that resolves
# to a hash of the replies of interest.
sub sendWithDsn_p ($proxyPort, %opt) {
    my $from = $opt{from} // 'MAIL FROM:<sender@foobar.com> RET=HDRS ENVID=QQ314159';
    my $client = RawSMTPClient->new(address => $TEST_HOST, port => $proxyPort);
    my %reply;
    return $client->connect_p
        ->then(sub { $client->command_p('EHLO test.client') })
        ->then(sub ($r) { $reply{plainEhlo} = $r; $client->command_p('STARTTLS') })
        ->then(sub { $client->startTLS_p })
        ->then(sub { $client->command_p('EHLO test.client') })
        ->then(sub ($r) { $reply{tlsEhlo} = $r; $client->authPlain_p('fooser', 's3cr3t') })
        ->then(sub ($r) {
            $reply{auth} = $r;
            $client->command_p($from);
        })
        ->then(sub ($r) {
            $reply{mail} = $r;
            $client->command_p(
                'RCPT TO:<another@foobaz.com> NOTIFY=SUCCESS,FAILURE ORCPT=rfc822;another@foobaz.com');
        })
        ->then(sub ($r) { $reply{rcpt} = $r; $client->command_p('DATA') })
        ->then(sub ($r) {
            $reply{data} = $r;
            $client->writeOnly(join "\r\n",
                'Subject: Some message subject',
                'From: from@foobar.com',
                'To: another@foobaz.com',
                '',
                'Some message text',
                '.',
                '');
            return $client->expectReply_p;
        })
        ->then(sub ($r) { $reply{end} = $r; $client->command_p('QUIT') })
        ->then(sub ($r) { $reply{quit} = $r; $client->close; return \%reply });
}

Mojo::IOLoop->next_tick(sub {
    $dsnUpstream->start;
    $plainUpstream->start;
    setupProxy($DSN_PROXY_PORT, $dsnUpstream);
    setupProxy($PLAIN_PROXY_PORT, $plainUpstream);

    sendWithDsn_p($DSN_PROXY_PORT)->then(sub ($reply) {

        # The proxy must announce DSN, or a conforming client (RFC 3461
        # section 4.1) will never send NOTIFY in the first place.
        like $reply->{plainEhlo}, qr/^250[- ]DSN\r?$/m,
            'EHLO before STARTTLS advertises DSN';
        like $reply->{tlsEhlo}, qr/^250[- ]DSN\r?$/m,
            'EHLO after STARTTLS advertises DSN';

        like $reply->{mail}, qr/^250 /, 'MAIL with RET and ENVID accepted';
        like $reply->{rcpt}, qr/^250 /, 'RCPT with NOTIFY and ORCPT accepted';
        like $reply->{end}, qr/^250 /, 'Message accepted';

        my $rcpt = $dsnUpstream->commandsMatching(qr/^RCPT/i);
        is scalar(@$rcpt), 1, 'One RCPT relayed upstream';
        is $rcpt->[0],
            'RCPT TO:<another@foobaz.com> NOTIFY=SUCCESS,FAILURE ORCPT=rfc822;another@foobaz.com',
            'NOTIFY and ORCPT forwarded verbatim to a DSN-capable upstream';

        my $mail = $dsnUpstream->commandsMatching(qr/^MAIL/i);
        is scalar(@$mail), 1, 'One MAIL relayed upstream';
        is $mail->[0], 'MAIL FROM:<sender@foobar.com> RET=HDRS ENVID=QQ314159',
            'RET and ENVID forwarded verbatim to a DSN-capable upstream';

        # A DSN is itself sent with an empty reverse path, so the proxy has to
        # be able to relay one.
        $dsnUpstream->clear;
        return sendWithDsn_p($DSN_PROXY_PORT, from => 'MAIL FROM:<>');
    })->then(sub ($reply) {
        like $reply->{mail}, qr/^250 /, 'MAIL FROM:<> accepted by the proxy';
        is $dsnUpstream->commandsMatching(qr/^MAIL/i)->[0], 'MAIL FROM:<>',
            'Null return path relayed upstream';

        return sendWithDsn_p($PLAIN_PROXY_PORT);
    })->then(sub ($reply) {

        # RFC 3461 section 5.2.2: a relay whose next hop cannot do DSN must not
        # pass the parameters on. Dropping them is strictly worse than issuing
        # our own DSN, but it must not cost us the delivery.
        like $reply->{rcpt}, qr/^250 /,
            'RCPT with NOTIFY accepted even when upstream lacks DSN';
        like $reply->{end}, qr/^250 /,
            'Message still delivered when upstream lacks DSN';

        my $rcpt = $plainUpstream->commandsMatching(qr/^RCPT/i);
        is scalar(@$rcpt), 1, 'One RCPT relayed to non-DSN upstream';
        is $rcpt->[0], 'RCPT TO:<another@foobaz.com>',
            'NOTIFY and ORCPT stripped for an upstream without DSN';

        my $mail = $plainUpstream->commandsMatching(qr/^MAIL/i);
        is $mail->[0], 'MAIL FROM:<sender@foobar.com>',
            'RET and ENVID stripped for an upstream without DSN';

        return;
    })->catch(sub ($err) {
        fail "Session failed: $err";
    })->finally(sub { Mojo::IOLoop->stop });
});

Mojo::IOLoop->start;

# The API must be told what the client asked for, so that policy can be applied
# to delivery notifications rather than them passing unseen.
my $lastCall = $testApi->calledWith->[-1];
is_deeply $lastCall->{mailParameters}, [
        { keyword => 'RET',   value => 'HDRS'     },
        { keyword => 'ENVID', value => 'QQ314159' },
    ], 'MAIL parameters passed to the API';
is_deeply $lastCall->{rcptParameters}, [
        {
            address => 'another@foobaz.com',
            parameters => [
                { keyword => 'NOTIFY', value => 'SUCCESS,FAILURE' },
                { keyword => 'ORCPT',  value => 'rfc822;another@foobaz.com' },
            ],
        },
    ], 'RCPT parameters passed to the API, one entry per recipient';
