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

plan tests => 14;

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
                ->finally(sub {
                    # Third connection: a line we reject must cost one 500 and
                    # leave the session usable, not wedge it for good.
                    my $bad = RawSMTPClient->new(
                        address => $TEST_HOST, port => $TEST_PORT);
                    $bad->connect_p
                        ->then(sub { $bad->command_p('EHLO client.example.com') })
                        ->then(sub {
                            $bad->writeOnly("MAIL FROM:<a\rb>\r\n");
                            $bad->expectReply_p;
                        })
                        ->then(sub ($r) {
                            $reply{malformed} = $r;
                            $bad->command_p('RSET');
                        })
                        ->then(sub ($r) { $reply{recovered} = $r; $bad->close; return })
                        ->catch(sub ($err) { fail "Recovery session failed: $err" })
                        ->finally(sub {
                            # Fourth connection: a mechanism we do not offer
                            # must be declined as a mechanism, not as a
                            # syntax error, or the client will not fall back.
                            my $auth = RawSMTPClient->new(
                                address => $TEST_HOST, port => $TEST_PORT);
                            $auth->connect_p
                                ->then(sub { $auth->command_p('EHLO client.example.com') })
                                ->then(sub { $auth->command_p('AUTH CRAM-MD5') })
                                ->then(sub ($r) {
                                    $reply{cramMd5} = $r;
                                    $auth->command_p('AUTH DIGEST-MD5 abcd');
                                })
                                ->then(sub ($r) {
                                    $reply{digestMd5} = $r; $auth->close; return
                                })
                                ->catch(sub ($err) { fail "AUTH session failed: $err" })
                                ->finally(sub { Mojo::IOLoop->stop });
                        });
                });
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

# A rejected line is answered once, and the connection carries on. Before the
# parser consumed what it rejected, the offending bytes stayed at the head of
# the read buffer: this RSET drew a third 500 rather than a 250, and every
# packet the client sent afterwards did the same.
like $reply{malformed}, qr/^500 /, 'A malformed line is rejected';
like $reply{recovered}, qr/^250 /, 'The next command is still answered';

# RFC 4954 section 4 allows a hyphen in a mechanism name. Rejecting one as a
# syntax error tells the client its line was malformed, which is not something
# it can act on; 504 tells it to offer a different mechanism.
like $reply{cramMd5}, qr/^504 /, 'A hyphenated mechanism draws 504, not 501';
like $reply{digestMd5}, qr/^504 /,
    'A hyphenated mechanism with an initial response draws 504 too';
