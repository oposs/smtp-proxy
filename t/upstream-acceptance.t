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

plan tests => 5;

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
        # The body contains lines that look like SMTP commands. They are
        # message content and must not be counted as commands the proxy sent.
        $client->writeOnly(join "\r\n",
            'Subject: x', 'From: a@b.com', '',
            'body',
            'RCPT TO:<smuggled@evil.example>',
            'MAIL FROM:<smuggled@evil.example>',
            '.', '');
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

# The recording server promises the command lines "minus the DATA payload", and
# the tests that count RCPT lines rely on that. It filtered only lines starting
# with a dot, so any body line beginning with a verb was counted as a command --
# the exact-count assertions elsewhere passed only because no fixture body
# happened to contain one.
is scalar(@{$upstream->commandsMatching(qr/^RCPT/i)}), 1,
    'A body line that looks like a RCPT is not counted as a command';
is_deeply $upstream->commandsMatching(qr/smuggled/), [],
    'No DATA payload line appears among the commands';
