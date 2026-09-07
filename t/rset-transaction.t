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

# RSET between two messages on one connection is routine -- RFC 5321 4.5.1 puts
# it in the minimum implementation, and Postfix's SMTP client sends it. It
# resets the transaction, not the session: the client authenticated once and is
# not asked to do so again, so the credentials it gave must survive.

plan tests => 11;

my $TEST_HOST = '127.0.0.1';
my $UPSTREAM_PORT = Mojo::IOLoop::Server->generate_port;
my $PROXY_PORT = Mojo::IOLoop::Server->generate_port;

my $upstream = RecordingSMTPServer->new(port => $UPSTREAM_PORT);
$upstream->start;

my $api = FakeAPI->new(result => { allow => 1, headers => [] });

SMTPProxy->new(
    log => Mojo::Log->new(level => $ENV{TEST_LOG_LEVEL} // 'fatal'),
    listen => [$TEST_HOST . ':' . $PROXY_PORT],
    tohost => $TEST_HOST,
    toport => $UPSTREAM_PORT,
    tls_cert => "$FindBin::Bin/certs-and-keys/server.crt",
    tls_key => "$FindBin::Bin/certs-and-keys/server.key",
    api => $api,
    service_name => 'smtp.proxy.service',
)->setup;

my %reply;
my $client = RawSMTPClient->new(address => $TEST_HOST, port => $PROXY_PORT);
$client->connect_p
    ->then(sub { $client->command_p('EHLO test.client') })
    ->then(sub { $client->command_p('STARTTLS') })
    ->then(sub { $client->startTLS_p })
    ->then(sub { $client->command_p('EHLO test.client') })
    ->then(sub { $client->authPlain_p('fooser', 's3cr3t') })
    ->then(sub ($r) { $reply{auth} = $r; $client->command_p('MAIL FROM:<sender@foobar.com>') })
    ->then(sub { $client->command_p('RCPT TO:<abandoned@foobaz.com>') })
    # Give up on that message and start another, without re-authenticating.
    ->then(sub { $client->command_p('RSET') })
    ->then(sub ($r) { $reply{rset} = $r; $client->command_p('MAIL FROM:<sender@foobar.com>') })
    ->then(sub ($r) { $reply{mail} = $r; $client->command_p('RCPT TO:<wanted@foobaz.com>') })
    ->then(sub ($r) { $reply{rcpt} = $r; $client->command_p('DATA') })
    ->then(sub ($r) {
        $reply{data} = $r;
        $client->writeOnly("Subject: after reset\r\nFrom: a\@b.com\r\n\r\nbody\r\n.\r\n");
        return $client->expectReply_p;
    })
    # RFC 5321 4.1.4: a mid-session EHLO resets the transaction exactly as RSET
    # does, and is a normal way for a client to start over. It must not cost
    # the session its authentication either.
    ->then(sub ($r) { $reply{accepted} = $r; $client->command_p('EHLO test.client') })
    ->then(sub ($r) { $reply{midEhlo} = $r; $client->command_p('MAIL FROM:<sender@foobar.com>') })
    ->then(sub ($r) { $reply{mail2} = $r; $client->command_p('RCPT TO:<third@foobaz.com>') })
    ->then(sub { $client->command_p('DATA') })
    ->then(sub {
        $client->writeOnly("Subject: after ehlo\r\nFrom: a\@b.com\r\n\r\nbody\r\n.\r\n");
        return $client->expectReply_p;
    })
    ->then(sub ($r) { $reply{accepted2} = $r; $client->command_p('QUIT') })
    ->then(sub { $client->close; return })
    ->catch(sub ($err) { fail "Session failed: $err" })
    ->finally(sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;

like $reply{rset}, qr/^250 /, 'RSET is accepted';
like $reply{mail}, qr/^250 /, 'A new MAIL is accepted after RSET';
like $reply{accepted}, qr/^250 /, 'The message after the RSET is accepted';

like $reply{midEhlo}, qr/^250[- ]/, 'A mid-session EHLO is accepted';
like $reply{midEhlo}, qr/^250[- ]DSN\r?$/m,
    'The mid-session EHLO answers with the extension list';
like $reply{mail2}, qr/^250 /, 'A new MAIL is accepted after the EHLO';
like $reply{accepted2}, qr/^250 /, 'The message after the EHLO is accepted';

my @calls = @{$api->calledWith};
is scalar(@calls), 2, 'The API was called once per message actually sent';
is_deeply [map { $_->{username} } @calls], ['fooser', 'fooser'],
    'The username survives both the RSET and the EHLO';
is_deeply [map { $_->{password} } @calls], ['s3cr3t', 's3cr3t'],
    'The password survives both the RSET and the EHLO';
is_deeply [map { $_->{to} } @calls],
    [['wanted@foobaz.com'], ['third@foobaz.com']],
    'Each message carries only its own recipients';
