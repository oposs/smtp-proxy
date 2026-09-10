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

# The same address may be given twice in one transaction with different DSN
# parameters, and the connection explicitly supports extra RCPTs. RFC 3461
# 5.2.1 requires the relayed RCPT to carry the parameters supplied for that
# recipient, so the two must not be merged: NOTIFY=NEVER quietly promoted to
# NOTIFY=SUCCESS is the opposite of what the sender asked for.

plan tests => 6;

my $TEST_HOST = '127.0.0.1';
my $PROXY_PORT = Mojo::IOLoop::Server->generate_port;

my $upstream = RecordingSMTPServer->new(
    port => Mojo::IOLoop::Server->generate_port,
    extensions => ['DSN'],
);
$upstream->start;

my $api = FakeAPI->new(result => { allow => 1, headers => [] });

SMTPProxy->new(
    log => Mojo::Log->new(level => $ENV{TEST_LOG_LEVEL} // 'fatal'),
    listen => [$TEST_HOST . ':' . $PROXY_PORT],
    tohost => $TEST_HOST,
    toport => $upstream->port,
    tls_cert => "$FindBin::Bin/certs-and-keys/server.crt",
    tls_key => "$FindBin::Bin/certs-and-keys/server.key",
    api => $api,
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
    ->then(sub { $client->command_p('RCPT TO:<dup@foobaz.com> NOTIFY=NEVER') })
    ->then(sub { $client->command_p('RCPT TO:<dup@foobaz.com> NOTIFY=SUCCESS') })
    ->then(sub { $client->command_p('RCPT TO:<other@foobaz.com> NOTIFY=DELAY') })
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

is_deeply $upstream->commandsMatching(qr/^RCPT/i), [
        'RCPT TO:<dup@foobaz.com> NOTIFY=NEVER',
        'RCPT TO:<dup@foobaz.com> NOTIFY=SUCCESS',
        'RCPT TO:<other@foobaz.com> NOTIFY=DELAY',
    ], 'Each RCPT is relayed with the parameters given for it';

my $call = $api->calledWith->[-1];
is_deeply $call->{to},
    ['dup@foobaz.com', 'dup@foobaz.com', 'other@foobaz.com'],
    'The API sees every recipient, in order';
is_deeply $call->{rcptParameters}, [
        { address => 'dup@foobaz.com',
          parameters => [{ keyword => 'NOTIFY', value => 'NEVER' }] },
        { address => 'dup@foobaz.com',
          parameters => [{ keyword => 'NOTIFY', value => 'SUCCESS' }] },
        { address => 'other@foobaz.com',
          parameters => [{ keyword => 'NOTIFY', value => 'DELAY' }] },
    ], 'The API can tell the two parameter sets apart';
is scalar(@{$call->{rcptParameters}}), scalar(@{$call->{to}}),
    'One parameter entry per recipient';
is_deeply [map { $_->{address} } @{$call->{rcptParameters}}], $call->{to},
    'The parameter entries are in recipient order';
