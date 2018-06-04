use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../thirdparty/lib/perl5";
use strict;
use warnings;
use v5.16;

use Mojo::Promise;
use Mojo::SMTP::Client;
use SMTPProxy::SMTPServer;
use Test::More;
use Test::Exception;

plan tests => 4;

my $TEST_HOST = '127.0.0.1';
my $TEST_PORT = 42349;

my $server = SMTPProxy::SMTPServer->new(
    address => $TEST_HOST,
    port => $TEST_PORT,
    tls_ca => "$FindBin::Bin/ca.crt",
    tls_cert => "$FindBin::Bin/server.crt",
    tls_key => "$FindBin::Bin/server.key",
    service_name => 'test.service.name',
);
$server->start(sub {
    my $connection = shift;
    isa_ok $connection, 'SMTPProxy::SMTPServer::Connection';
    $connection->mail(sub {
        my ($from, $parameters) = @_;
        is $from, 'sender@foobar.com', 'Correct mail from';
        is scalar(@$parameters), 0, 'No SMTP parameters';
    });
});

Mojo::IOLoop->next_tick(\&makeTestConnection);
Mojo::IOLoop->start;

sub makeTestConnection {
    my $smtp = Mojo::SMTP::Client->new(address => $TEST_HOST, port => $TEST_PORT, autodie => 1);
    $smtp->send(
        starttls => 1,
        auth => {login => 'fooser', password => 's3cr3t'},
        from => 'sender@foobar.com',
        to   => 'another@foobaz.com',
        data => 'Hi this is a message lol',
        quit => 1,
        sub {
            my ($smtp, $resp) = @_;
            ok(!($resp->error), 'No error on sending');
            Mojo::IOLoop->stop;
        }
    );
}
