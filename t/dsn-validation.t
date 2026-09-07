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

# Announcing DSN is what makes a conforming client send these parameters, and
# RFC 3461 5.1 makes answering 501 to a syntactically invalid one a MUST for a
# server that announces it. They were accepted with 250 and relayed verbatim,
# so a malformed one was not discovered until the upstream saw it -- after the
# client had transferred the whole message body.

plan tests => 16;

my $TEST_HOST = '127.0.0.1';
my $TEST_PORT = Mojo::IOLoop::Server->generate_port;

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
    $connection->data(sub { Mojo::Promise->resolve });
});

# A rejected MAIL or RCPT leaves the state where it was, so one connection can
# work through the whole list.
my @script = (
    # [description, command line, expected leading digit]
    ['RET with an unknown value',      'MAIL FROM:<a@b.com> RET=PARTIAL',            5],
    ['RET with no value',              'MAIL FROM:<a@b.com> RET',                    5],
    ['ENVID over the 100 char limit',  'MAIL FROM:<a@b.com> ENVID=' . ('x' x 101),   5],
    ['ENVID that is not xtext',        'MAIL FROM:<a@b.com> ENVID=has+zz',           5],
    ['a repeated ENVID',               'MAIL FROM:<a@b.com> ENVID=one ENVID=two',    5],
    ['a repeated RET',                 'MAIL FROM:<a@b.com> RET=FULL RET=HDRS',      5],
    ['valid MAIL DSN parameters',      'MAIL FROM:<a@b.com> RET=HDRS ENVID=QQ314159',2],
    ['NOTIFY with an unknown value',   'RCPT TO:<c@d.com> NOTIFY=MAYBE',             5],
    ['NEVER combined with SUCCESS',    'RCPT TO:<c@d.com> NOTIFY=NEVER,SUCCESS',     5],
    ['NOTIFY listing a value twice',   'RCPT TO:<c@d.com> NOTIFY=DELAY,DELAY',       5],
    ['NOTIFY with an empty element',   'RCPT TO:<c@d.com> NOTIFY=SUCCESS,',          5],
    ['ORCPT with no address type',     'RCPT TO:<c@d.com> ORCPT=nosemicolon',        5],
    ['ORCPT over the 500 char limit',  'RCPT TO:<c@d.com> ORCPT=rfc822;' . ('x' x 500), 5],
    ['a repeated NOTIFY',              'RCPT TO:<c@d.com> NOTIFY=DELAY NOTIFY=NEVER',5],
    ['valid RCPT DSN parameters',
        'RCPT TO:<c@d.com> NOTIFY=SUCCESS,FAILURE ORCPT=rfc822;c@d.com',             2],
    ['NOTIFY=NEVER on its own',        'RCPT TO:<c@d.com> NOTIFY=NEVER',             2],
);

my @replies;
my $client = RawSMTPClient->new(address => $TEST_HOST, port => $TEST_PORT);
my $run;
$run = sub ($index) {
    if ($index > $#script) {
        $client->close;
        Mojo::IOLoop->stop;
        return;
    }
    $client->command_p($script[$index][1])
        ->then(sub ($r) { push @replies, $r; $run->($index + 1) })
        ->catch(sub ($err) { fail "Script step $index failed: $err"; Mojo::IOLoop->stop });
};
$client->connect_p
    ->then(sub { $client->command_p('EHLO client.example.com') })
    ->then(sub { $run->(0) })
    ->catch(sub ($err) { fail "Session failed: $err"; Mojo::IOLoop->stop });
Mojo::IOLoop->start;

for my $index (0 .. $#script) {
    my ($desc, undef, $expected) = @{$script[$index]};
    like $replies[$index], qr/^$expected\d\d /,
        "${expected}xx for $desc";
}
