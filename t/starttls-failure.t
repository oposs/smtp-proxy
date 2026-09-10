use FindBin;
use lib "$FindBin::Bin";
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../thirdparty/lib/perl5";
use strict;
use warnings;
use Mojo::Base -strict, -signatures;

use Mojo::IOLoop;
use Mojo::IOLoop::Server;
use Mojo::Log;
use Mojo::Promise;
use RawSMTPClient;
use SMTPProxy::SMTPServer;
use Test::More;

# A TLS negotiation that fails is not an exotic case: any client that says
# STARTTLS and then does not speak TLS reaches it, unauthenticated and at will.
# The error handler closed the stream and then went on reading from $self --
# but closing the stream is what destroys the connection that owns it, and
# $self is weakened by then, so the next statement ran on undef and took the
# reactor's I/O watcher down with it.

plan tests => 3;

my $TEST_HOST = '127.0.0.1';
my $TEST_PORT = Mojo::IOLoop::Server->generate_port;

my $server = SMTPProxy::SMTPServer->new(
    log => Mojo::Log->new(level => $ENV{TEST_LOG_LEVEL} // 'fatal'),
    listen => [$TEST_HOST . ':' . $TEST_PORT],
    service_name => 'test.service.name',
    tls_cert => "$FindBin::Bin/certs-and-keys/server.crt",
    tls_key => "$FindBin::Bin/certs-and-keys/server.key",
    require_starttls => 0,
    require_auth => 0,
);
$server->setup(sub ($connection) {
    $connection->auth(sub { Mojo::Promise->resolve });
    $connection->mail(sub { Mojo::Promise->resolve });
    $connection->rcpt(sub { Mojo::Promise->resolve });
    $connection->data(sub { Mojo::Promise->resolve });
});

my @warnings;
local $SIG{__WARN__} = sub { push @warnings, $_[0] };

my $goAhead;
my $client = RawSMTPClient->new(address => $TEST_HOST, port => $TEST_PORT);
$client->connect_p
    ->then(sub { $client->command_p('EHLO client.example.com') })
    ->then(sub { $client->command_p('STARTTLS') })
    ->then(sub ($r) {
        $goAhead = $r;
        # Anything that is not a TLS ClientHello will do.
        $client->writeOnly("this is not a TLS handshake\r\n");
        Mojo::IOLoop->timer(1 => sub { Mojo::IOLoop->stop });
        return;
    })
    ->catch(sub ($err) { fail "Session failed: $err"; Mojo::IOLoop->stop });
Mojo::IOLoop->start;

like $goAhead, qr/^220 /, 'STARTTLS is answered before the handshake';
is_deeply [grep { /Can't call method|undefined value/ } @warnings], [],
    'A failed TLS negotiation raises no exception in the reactor';

# The point of the handler is still to shut the connection down.
my $second = RawSMTPClient->new(address => $TEST_HOST, port => $TEST_PORT);
my $stillServing;
$second->connect_p
    ->then(sub ($greeting) { $stillServing = $greeting; $second->close; return })
    ->catch(sub ($err) { fail "Server stopped accepting: $err" })
    ->finally(sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;
like $stillServing, qr/^220 /, 'The server still accepts new connections';
