use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../thirdparty/lib/perl5";
use strict;
use warnings;
use v5.16;

use Mojo::IOLoop::Server;
use Mojo::Log;
use Mojo::Promise;
use Mojo::SMTP::Client;
use SMTPProxy::SMTPServer;
use Test::More;
use Test::Exception;

plan tests => 17;

my $TEST_HOST = '127.0.0.1';
my $TEST_PORT = Mojo::IOLoop::Server->generate_port;

my $server = SMTPProxy::SMTPServer->new(
    log => Mojo::Log->new(level => 'debug'),
    listen => [$TEST_HOST.':'.$TEST_PORT],
    tls_ca => "$FindBin::Bin/certs-and-keys/ca.crt",
    tls_cert => "$FindBin::Bin/certs-and-keys/server.crt",
    tls_key => "$FindBin::Bin/certs-and-keys/server.key",
    service_name => 'test.service.name',
);
$server->setup(sub {
    my $connection = shift;
    isa_ok $connection, 'SMTPProxy::SMTPServer::Connection';
    $connection->auth(sub {
        my ($authzid, $authcid, $password) = @_;
        is $authzid, '', 'Correct authzid passed to auth callback';
        is $authcid, 'fooser', 'Correct authcid passed to auth callback';
        is $password, 's3cr3t', 'Correct password passed to auth callback';
        return Mojo::Promise->new->resolve;
    });
    $connection->rset(sub {
        pass "Reset callback was called";
    });
    $connection->mail(sub {
        my ($from, $parameters) = @_;
        is $from, 'sender@foobar.com', 'Correct mail from';
        is scalar(@$parameters), 0, 'No MAIL parameters';
        return Mojo::Promise->new->resolve;
    });
    my $rcptCount = 0;
    $connection->rcpt(sub {
        my ($to, $parameters) = @_;
        if ($rcptCount++ == 0) {
            is $to, 'another@foobaz.com', "Correct mail from ($rcptCount)";
        }
        else {
            is $to, 'brother@foobaz.com', "Correct mail from ($rcptCount)";
        }
        is scalar(@$parameters), 0, "No RCPT parameters ($rcptCount)";
        return Mojo::Promise->new->resolve;
    });
    $connection->data(sub {
        my ($headersPromise, $bodyPromise) = @_;
        isa_ok $headersPromise, 'Mojo::Promise', 'Get a headers promise';
        isa_ok $bodyPromise, 'Mojo::Promise', 'Get a body promise';
        my $result = Mojo::Promise->new;
        $headersPromise->then(sub {
            my $headers = shift;
            my $expectedHeaders = join "\r\n",
                'Subject: Some message subject',
                'From: from@foobar.com',
                'To: another@foobaz.com',
                'Cc: brother@foobaz.com',
                '';
            is $headers, $expectedHeaders, 'Got the expected headers';
        });
        $bodyPromise->then(sub {
            my $body = shift;
            my $expectedBody = join "\r\n",
                'Some message text',
                'More message text',
                '';
            is $body, $expectedBody, 'Got the expected body';
            $result->resolve;
        });
        return $result;
    });
    $connection->quit(sub {
        pass 'Quit called';
    });
});

Mojo::IOLoop->next_tick(\&makeTestConnection);
Mojo::IOLoop->start;

sub makeTestConnection {
    my $smtp = Mojo::SMTP::Client->new(
        address => $TEST_HOST,
        port => $TEST_PORT,
        autodie => 1,
        tls_verify => 0,
    );
    $smtp->send(
        starttls => 1,
        auth     => {login => 'fooser', password => 's3cr3t'},
        reset    => 1,
        from     => 'sender@foobar.com',
        to       => ['another@foobaz.com', 'brother@foobaz.com'],
        data     => join("\r\n",
                        'Subject: Some message subject',
                        'From: from@foobar.com',
                        'To: another@foobaz.com',
                        'Cc: brother@foobaz.com',
                        '',
                        'Some message text',
                        'More message text'),
        quit     => 1,
        sub {
            my ($smtp, $resp) = @_;
            ok(!($resp->error), 'No error on sending');
            Mojo::IOLoop->stop;
        }
    );
}
