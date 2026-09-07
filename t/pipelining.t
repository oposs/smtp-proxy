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

# RFC 2920: a client may send a group of commands in one write and read the
# replies afterwards. Everything that has arrived has to be processed, in
# order, one command at a time -- so this exercises three things at once: that
# the reader does not stop after the first command in a packet, that a command
# is not dispatched while the previous one is still deciding, and that the
# message terminator hands back what follows it instead of destroying it.

plan tests => 9;

my $TEST_HOST = '127.0.0.1';
my $TEST_PORT = Mojo::IOLoop::Server->generate_port;

# MAIL answers on a later tick than RCPT would if nothing serialised them.
my $slowMail = 0;
my @callbackOrder;
my $server = SMTPProxy::SMTPServer->new(
    log => Mojo::Log->new(level => $ENV{TEST_LOG_LEVEL} // 'fatal'),
    listen => [$TEST_HOST . ':' . $TEST_PORT],
    service_name => 'test.service.name',
    require_starttls => 0,
    require_auth => 0,
);
$server->setup(sub ($connection) {
    $connection->auth(sub { Mojo::Promise->resolve });
    $connection->mail(sub {
        push @callbackOrder, 'mail';
        return Mojo::Promise->resolve unless $slowMail;
        my $promise = Mojo::Promise->new;
        Mojo::IOLoop->timer(0.25 => sub { $promise->resolve });
        return $promise;
    });
    $connection->rcpt(sub { push @callbackOrder, 'rcpt'; Mojo::Promise->resolve });
    $connection->rset(sub { });
    $connection->data(sub ($headersPromise, $bodyPromise) {
        $headersPromise->then(sub { });
        $bodyPromise->then(sub { });
        return Mojo::Promise->resolve('accepted');
    });
});

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

my %got;
my $client = RawSMTPClient->new(address => $TEST_HOST, port => $TEST_PORT);
$client->connect_p
    ->then(sub {
        # Three commands, one write.
        $client->writeOnly("EHLO client.example.com\r\nNOOP\r\nNOOP\r\n");
        return expectReplies_p($client, 3);
    })
    ->then(sub ($replies) {
        $got{batch} = $replies;
        # A pipelined transaction where the first command is slow to settle.
        $slowMail = 1;
        @callbackOrder = ();
        $client->writeOnly("MAIL FROM:<a\@b.com>\r\nRCPT TO:<c\@d.com>\r\nDATA\r\n");
        return expectReplies_p($client, 3);
    })
    ->then(sub ($replies) {
        $got{transaction} = $replies;
        $got{order} = [@callbackOrder];
        # The terminating dot and the next command in one write.
        $client->writeOnly("Subject: x\r\n\r\nbody\r\n.\r\nQUIT\r\n");
        return expectReplies_p($client, 2);
    })
    ->then(sub ($replies) { $got{end} = $replies; $client->close; return })
    ->catch(sub ($err) { fail "Session failed: $err" })
    ->finally(sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;

is scalar(@{$got{batch} // []}), 3, 'Three pipelined commands draw three replies';
like $got{batch}[0], qr/^250[- ]/, 'The EHLO in the group is answered';
is $got{batch}[1], "250 OK\r\n", 'The first NOOP behind it is answered';
is $got{batch}[2], "250 OK\r\n", 'The second NOOP behind it is answered';

is_deeply $got{order}, ['mail', 'rcpt'],
    'The slow MAIL is settled before the RCPT behind it is dispatched';
like $got{transaction}[0], qr/^250 /, 'MAIL is answered first';
like $got{transaction}[1], qr/^250 /, 'RCPT is answered second, not 503';
like $got{transaction}[2], qr/^354 /, 'DATA is answered third';

like $got{end}[1], qr/^221 /,
    'A QUIT written with the terminating dot is still answered';
