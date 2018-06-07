use FindBin;
use lib "$FindBin::Bin/lib";
use lib "$FindBin::Bin/thirdparty/lib/perl5";
use strict;
use warnings;
use v5.16;

use Mojo::Log;
use Mojo::Promise;
use SMTPProxy::SMTPServer;

my $TEST_HOST = 'localhost';
my $TEST_PORT = 4459;

my $server = SMTPProxy::SMTPServer->new(
    log => Mojo::Log->new(level => 'debug'),
    address => $TEST_HOST,
    port => $TEST_PORT,
    service_name => 'test.service.name',
    require_tlsstart => 0,
    require_auth => 0,
);
$server->setup(sub {
    my $connection = shift;
    $connection->auth_plain(sub {
        my ($authzid, $authcid, $password) = @_;
        say "Auth $authcid, $password";
        return Mojo::Promise->new->resolve;
    });
    $connection->mail(sub {
        my ($from, $parameters) = @_;
        say "From: $from";
        return Mojo::Promise->new->resolve;
    });
    my $rcptCount = 0;
    $connection->rcpt(sub {
        my ($to, $parameters) = @_;
        say "To: $to";
        return Mojo::Promise->new->resolve;
    });
    $connection->data(sub {
        my ($headersPromise, $bodyPromise) = @_;
        my $result = Mojo::Promise->new;
        $headersPromise->then(sub {
            my $headers = shift;
            say "Headers:\n$headers";
        });
        $bodyPromise->then(sub {
            my $body = shift;
            say "Body:\n$body";
            $result->resolve;
        });
        return $result;
    });
    $connection->quit(sub {
        say 'Quit called';
    });
});
Mojo::IOLoop->start;
