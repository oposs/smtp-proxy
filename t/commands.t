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

plan tests => 10;

my $TEST_HOST = '127.0.0.1';
my $TEST_PORT = Mojo::IOLoop::Server->generate_port;

my $server = SMTPProxy::SMTPServer->new(
    log => Mojo::Log->new(level => $ENV{TEST_LOG_LEVEL} // 'warn'),
    listen => [$TEST_HOST . ':' . $TEST_PORT],
    service_name => 'test.service.name',
    require_starttls => 0,
    require_auth => 0,
);
$server->setup(sub ($connection) {
    $connection->mail(sub { Mojo::Promise->resolve });
    $connection->rcpt(sub { Mojo::Promise->resolve });
    $connection->data(sub { Mojo::Promise->resolve });
});

my %reply;
Mojo::IOLoop->next_tick(sub {
    my $client = RawSMTPClient->new(address => $TEST_HOST, port => $TEST_PORT);
    $client->connect_p
        ->then(sub ($greeting) {
            $reply{greeting} = $greeting;
            $client->command_p('EHLO client.example.com');
        })
        ->then(sub ($r) { $reply{ehlo} = $r; $client->command_p('NOOP') })
        ->then(sub ($r) { $reply{noop} = $r; $client->command_p('NOOP keep alive') })
        ->then(sub ($r) { $reply{noopArg} = $r; $client->command_p('RSET') })
        ->then(sub ($r) { $reply{rset} = $r; $client->command_p('QUIT') })
        ->then(sub ($r) { $reply{quit} = $r; $client->close; return })
        ->catch(sub ($err) { fail "Session failed: $err" })
        ->finally(sub {
            # Second connection, this time greeting with HELO.
            my $helo = RawSMTPClient->new(address => $TEST_HOST, port => $TEST_PORT);
            $helo->connect_p
                ->then(sub { $helo->command_p('HELO client.example.com') })
                ->then(sub ($r) { $reply{helo} = $r; $helo->close; return })
                ->catch(sub ($err) { fail "HELO session failed: $err" })
                ->finally(sub { Mojo::IOLoop->stop });
        });
});
Mojo::IOLoop->start;

like $reply{greeting}, qr/^220 /, 'Server greets on connect';

# EHLO announces what the server can do.
like $reply{ehlo}, qr/^250[- ]/, 'EHLO accepted';
like $reply{ehlo}, qr/^250[- ]STARTTLS\r?$/m, 'EHLO announces STARTTLS';
like $reply{ehlo}, qr/^250[- ]DSN\r?$/m, 'EHLO announces DSN';

# HELO is basic SMTP. RFC 5321 4.1.1.1 has it answered with a single line, and
# announcing extensions to a client that did not ask for them is wrong.
like $reply{helo}, qr/^250 /, 'HELO accepted';
is scalar(() = $reply{helo} =~ /\r\n/g), 1, 'HELO answered with a single line';
unlike $reply{helo}, qr/STARTTLS|DSN|AUTH/, 'HELO reply announces no extensions';

# NOOP and RSET are in the RFC 5321 4.5.1 minimum implementation.
like $reply{noop}, qr/^250 /, 'NOOP accepted';
like $reply{noopArg}, qr/^250 /, 'NOOP with an argument accepted';
like $reply{rset}, qr/^250 /, 'RSET accepted';
