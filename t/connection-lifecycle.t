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
use SMTPProxy;
use Test::More;

plan tests => 4;

# A client may hang up while the proxy is still relaying its mail. The
# connection object is then gone by the time the relay settles, and the
# callbacks that wanted to reply to the client must cope with that instead of
# dying and leaving a rejected promise nobody handles.

my $TEST_HOST = '127.0.0.1';
my $UPSTREAM_PORT = Mojo::IOLoop::Server->generate_port;
my $PROXY_PORT = Mojo::IOLoop::Server->generate_port;

open my $logHandle, '>', \my $logOutput or die "Cannot open log buffer: $!";
my $log = Mojo::Log->new(handle => $logHandle, level => 'info');

# Upstream that greets, then drops the connection shortly after the relay
# starts talking to it, so the relay fails after the client has gone.
Mojo::IOLoop->server({address => $TEST_HOST, port => $UPSTREAM_PORT} => sub ($loop, $stream, $id) {
    $stream->write("220 doomed.upstream ready\r\n");
    $stream->on(read => sub ($stream, $bytes) {
        $stream->{closing} //= Mojo::IOLoop->timer(1 => sub { $stream->close });
    });
});

SMTPProxy->new(
    log => $log,
    listen => [$TEST_HOST . ':' . $PROXY_PORT],
    tohost => $TEST_HOST,
    toport => $UPSTREAM_PORT,
    tls_cert => "$FindBin::Bin/certs-and-keys/server.crt",
    tls_key => "$FindBin::Bin/certs-and-keys/server.key",
    api => FakeAPI->new(result => { allow => 1, headers => [] }),
    service_name => 'smtp.proxy.service',
)->setup;

my @warnings;
local $SIG{__WARN__} = sub { push @warnings, $_[0] };

my $client = RawSMTPClient->new(address => $TEST_HOST, port => $PROXY_PORT);
$client->connect_p
    ->then(sub { $client->command_p('EHLO test.client') })
    ->then(sub { $client->command_p('STARTTLS') })
    ->then(sub { $client->startTLS_p })
    ->then(sub { $client->command_p('EHLO test.client') })
    ->then(sub { $client->authPlain_p('fooser', 's3cr3t') })
    ->then(sub { $client->command_p('MAIL FROM:<sender@foobar.com>') })
    ->then(sub { $client->command_p('RCPT TO:<another@foobaz.com>') })
    ->then(sub { $client->command_p('DATA') })
    ->then(sub {
        $client->writeOnly("Subject: x\r\nFrom: a\@b.com\r\n\r\nbody\r\n.\r\n");
        # Hang up while the proxy is still relaying.
        Mojo::IOLoop->timer(0.3 => sub { $client->close });
        return;
    })
    ->catch(sub ($err) { fail "Client session failed: $err" });

# Long enough for the upstream to drop the relay after the client has gone.
Mojo::IOLoop->timer(4 => sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;

my @unhandled = grep { /Unhandled rejected promise/ } @warnings;
is scalar(@unhandled), 0, 'No unhandled rejected promise'
    or diag "Got: $unhandled[0]";

my @undefined = grep { /on an undefined value/ } @warnings;
is scalar(@undefined), 0, 'Nothing called a method on the departed connection'
    or diag "Got: $undefined[0]";

# Proves the test actually exercised the race rather than passing vacuously:
# the connection really was gone by the time the relay settled.
like $logOutput, qr/left before/,
    'Proxy noticed the client had gone before the relay settled';
unlike $logOutput, qr/Can't call method/,
    'No method call errors logged';
