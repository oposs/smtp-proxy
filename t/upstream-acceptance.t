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

# When the upstream accepts a message it says so in the text of its 250, and in
# production that text is the receiving MTA's queue id -- the identifier an
# operator needs to trace the message from this point on. The proxy is supposed
# to hand that text back to the submitting client rather than inventing one.

plan tests => 3;

my $TEST_HOST = '127.0.0.1';
my $UPSTREAM_PORT = Mojo::IOLoop::Server->generate_port;
my $PROXY_PORT = Mojo::IOLoop::Server->generate_port;

my $upstream = RecordingSMTPServer->new(port => $UPSTREAM_PORT);
$upstream->start;

SMTPProxy->new(
    log => Mojo::Log->new(level => $ENV{TEST_LOG_LEVEL} // 'fatal'),
    listen => [$TEST_HOST . ':' . $PROXY_PORT],
    tohost => $TEST_HOST,
    toport => $UPSTREAM_PORT,
    tls_cert => "$FindBin::Bin/certs-and-keys/server.crt",
    tls_key => "$FindBin::Bin/certs-and-keys/server.key",
    api => FakeAPI->new(result => { allow => 1, headers => [] }),
    service_name => 'smtp.proxy.service',
)->setup;

my $accepted;
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
    ->then(sub ($r) { $accepted = $r; $client->command_p('QUIT') })
    ->then(sub { $client->close; return })
    ->catch(sub ($err) { fail "Session failed: $err" })
    ->finally(sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;

like $accepted, qr/^250 /, 'The message is accepted';
like $accepted, qr/\QOK message accepted\E/,
    "The upstream's acceptance text reaches the client";
unlike $accepted, qr/^250 OK:\s*\r?\n/,
    'The client is not answered with an empty acceptance text';
