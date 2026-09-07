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

# The relay can take until its inactivity timeout to settle. A client that does
# not wait for the reply to its terminating dot -- RFC 2920 says it must, and
# some do not -- used to have that next command dispatched immediately, so the
# relay came back into a transaction that had already been replaced: an
# unsolicited reply with no command outstanding, which offsets every later
# reply on the connection, and a state write that wound the live transaction
# backwards.
#
# The command behind the dot now waits, so the replies come back in the order
# the commands were sent and each one answers its own command.

plan tests => 5;

my $TEST_HOST = '127.0.0.1';
my $TEST_PORT = Mojo::IOLoop::Server->generate_port;

my $slowRelay;
my $server = SMTPProxy::SMTPServer->new(
    log => Mojo::Log->new(level => $ENV{TEST_LOG_LEVEL} // 'fatal'),
    listen => [$TEST_HOST . ':' . $TEST_PORT],
    service_name => 'test.service.name',
    require_starttls => 0,
    require_auth => 0,
);
$server->setup(sub ($connection) {
    $connection->auth(sub { Mojo::Promise->resolve });
    $connection->mail(sub { Mojo::Promise->resolve });
    $connection->rcpt(sub { Mojo::Promise->resolve });
    $connection->rset(sub { });
    # Stands in for a relay that has not answered yet.
    $connection->data(sub ($headersPromise, $bodyPromise) {
        $headersPromise->then(sub { });
        $bodyPromise->then(sub { });
        return $slowRelay = Mojo::Promise->new;
    });
});

my %reply;
my @order;
my $client = RawSMTPClient->new(address => $TEST_HOST, port => $TEST_PORT);

# Reads exactly $count replies, however they are packed into TCP segments.
sub expectReplies_p ($client, $count) {
    my @replies;
    my $next;
    $next = sub {
        return Mojo::Promise->resolve(\@replies) unless $count--;
        return $client->expectReply_p->then(sub ($r) { push @replies, $r; $next->() });
    };
    return $next->();
}

$client->connect_p
    ->then(sub { $client->command_p('EHLO client.example.com') })
    ->then(sub { $client->command_p('MAIL FROM:<a@b.com>') })
    ->then(sub { $client->command_p('RCPT TO:<c@d.com>') })
    ->then(sub { $client->command_p('DATA') })
    ->then(sub {
        # End the message and, without waiting for the reply, abandon it and
        # start a fresh transaction.
        $client->writeOnly("Subject: x\r\n\r\nbody\r\n.\r\nRSET\r\nMAIL FROM:<e\@f.com>\r\n");
        # The relay for the first message only comes back once all of that has
        # been sitting in the server's buffer for a while.
        Mojo::IOLoop->timer(0.3 => sub { $slowRelay->resolve('queued as ABC123') });
        return expectReplies_p($client, 3);
    })
    ->then(sub ($replies) {
        @order = @$replies;
        return $client->command_p('RCPT TO:<g@h.com>');
    })
    ->then(sub ($r) { $reply{secondRcpt} = $r; $client->command_p('QUIT') })
    ->then(sub ($r) { $reply{quit} = $r; $client->close; return })
    ->catch(sub ($err) { fail "Session failed: $err" })
    ->finally(sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;

is scalar(@order), 3, 'Each of the three commands is answered exactly once';
like $order[0], qr/^250 OK: queued as ABC123/,
    'The message is answered first, with the relay result that belongs to it';
is $order[1], "250 OK\r\n", 'The RSET behind it gets its own reply, in order';
like $order[2], qr/^250 /, 'The MAIL behind that is answered last';

# If the abandoned settlement had written state, this RCPT would draw 503.
like $reply{secondRcpt}, qr/^250 /,
    'The live transaction still accepts RCPT, so its state was not overwritten';
