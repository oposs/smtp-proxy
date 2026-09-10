use FindBin;
use lib "$FindBin::Bin";
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../thirdparty/lib/perl5";
use strict;
use warnings;
use Mojo::Base -strict, -signatures;

use Mojo::IOLoop;
use Mojo::IOLoop::Server;
use RawSMTPClient;
use Test::More;

# Mojo::IOLoop::Stream never emits 'error' on EOF or on an inactivity timeout:
# it emits 'timeout' and then calls close, or on EOF just close. RawSMTPClient
# settled its pending promise from the 'error' handler alone, so a server that
# went away mid-reply left the promise unsettled forever -- and a test waiting
# on it hung with no output and no plan failure instead of reporting the
# server-side regression that caused it. A test harness that hangs is worse
# than one that fails, so the client must settle on every way a reply can fail
# to arrive.

plan tests => 4;

my $TEST_HOST = '127.0.0.1';

# A server that accepts the connection and hangs up without saying anything.
my $silentPort = Mojo::IOLoop::Server->generate_port;
Mojo::IOLoop->server({address => $TEST_HOST, port => $silentPort} => sub ($loop, $stream, $id) {
    $stream->close;
});

# A server that greets, then hangs up while a reply to a command is awaited.
my $partialPort = Mojo::IOLoop::Server->generate_port;
Mojo::IOLoop->server({address => $TEST_HOST, port => $partialPort} => sub ($loop, $stream, $id) {
    $stream->write("220 abrupt.example ESMTP ready\r\n");
    $stream->on(read => sub ($stream, $bytes) { $stream->close });
});

# Every wait in this file is bounded, so a regression fails the file rather
# than hanging it.
sub settle ($promise) {
    my ($outcome, $error);
    my $guard = Mojo::IOLoop->timer(5 => sub { Mojo::IOLoop->stop });
    $promise->then(sub { $outcome = 'resolved' }, sub ($err = '') {
        $outcome = 'rejected';
        $error = $err;
    })->finally(sub { Mojo::IOLoop->stop });
    Mojo::IOLoop->start;
    Mojo::IOLoop->remove($guard);
    return ($outcome, $error);
}

my $silent = RawSMTPClient->new(address => $TEST_HOST, port => $silentPort);
my ($outcome, $error) = settle($silent->connect_p);
is $outcome, 'rejected', 'A greeting that never arrives rejects the promise';
ok defined $error && length $error, 'The rejection carries a reason';

my $partial = RawSMTPClient->new(address => $TEST_HOST, port => $partialPort);
my ($greeted) = settle($partial->connect_p);
is $greeted, 'resolved', 'The greeting is still read normally';
my ($cut) = settle($partial->command_p('EHLO client.example.com'));
is $cut, 'rejected', 'A connection cut mid-command rejects the pending reply';
