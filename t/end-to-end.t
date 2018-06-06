use FindBin;
use lib "$FindBin::Bin";
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../thirdparty/lib/perl5";
use strict;
use warnings;
use v5.16;

use FakeAPI;
use Mojo::Promise;
use Mojo::SMTP::Client;
use SMTPProxy;
use SMTPProxy::SMTPServer;
use Test::More;

plan tests => 5;

# Test infrastructure

my $TEST_HOST = '127.0.0.1';
my $TEST_PROXY_PORT = Mojo::IOLoop::Server->generate_port;
my $TEST_TO_PORT = Mojo::IOLoop::Server->generate_port;
my $TEST_LOG = Mojo::Log->new(level => 'warn');

my $testApi = FakeAPI->new;
my %toSMTPServerSent;
sub setupTestSMTPTarget {
    my $server = SMTPProxy::SMTPServer->new(
        log => $TEST_LOG,
        address => $TEST_HOST,
        port => $TEST_TO_PORT,
        service_name => 'test.to.service',
        require_starttls => 0,
        require_auth => 0,
    );
    $server->start(sub {
        my $connection = shift;
        $connection->auth_plain(sub {
            my ($authzid, $authcid, $password) = @_;
            fail "Target SMTP server should not be auth'd";
            return Mojo::Promise->reject;
        });
        $connection->mail(sub {
            my ($from, $parameters) = @_;
            $toSMTPServerSent{from} = $from;
            return Mojo::Promise->new->resolve;
        });
        $connection->rcpt(sub {
            my ($to, $parameters) = @_;
            $toSMTPServerSent{to} //= [];
            push @{$toSMTPServerSent{to}}, $to;
            return Mojo::Promise->new->resolve;
        });
        $connection->data(sub {
            my ($headersPromise, $bodyPromise) = @_;
            my $result = Mojo::Promise->new;
            $headersPromise->then(sub {
                $toSMTPServerSent{headers} = shift;
            });
            $bodyPromise->then(sub {
                $toSMTPServerSent{body} = shift;
                $result->resolve;
            });
        });
        $connection->vrfy(sub {
            return Mojo::Promise->new->reject(553, 'User ambiguous');
        });
    });
}

sub setupProxy {
    my $proxy = SMTPProxy->new(
        log => $TEST_LOG,
        listenhost => $TEST_HOST,
        listenport => $TEST_PROXY_PORT,
        tohost => $TEST_HOST,
        toport => $TEST_TO_PORT,
        tls_cert => "$FindBin::Bin/certs-and-keys/server.crt",
        tls_key => "$FindBin::Bin/certs-and-keys/server.key",
        api => $testApi,
        service_name => 'smtp.proxy.service'
    );
    $proxy->run;
}

sub runTestCases {
    my @testCases = @_;
    Mojo::IOLoop->next_tick(sub {
        setupTestSMTPTarget();
        setupProxy();
        runOneTestCase(@testCases);
    });
    Mojo::IOLoop->start;
}

sub runOneTestCase {
    my ($test, @rest) = @_;
    %toSMTPServerSent = ();
    $testApi->clear();
    $test->(@rest
        ? sub { runOneTestCase(@rest) }
        : sub { Mojo::IOLoop->stop });
}

# Tests

runTestCases(\&allowedSimple);

sub allowedSimple {
    my $done = shift;

    $testApi->result({
        allow => 1,
        headers => []
    });

    my $smtp = Mojo::SMTP::Client->new(
        address => $TEST_HOST,
        port => $TEST_PROXY_PORT,
        autodie => 1,
        tls_verify => 0,
    );
    $smtp->send(
        starttls => 1,
        auth     => {login => 'fooser', password => 's3cr3t'},
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
            ok(!($resp->error), 'Allowed mail accepted by proxy');

            is $toSMTPServerSent{from}, 'sender@foobar.com',
                'Envelope from correctly relayed';
            is_deeply $toSMTPServerSent{to},
                ['another@foobaz.com', 'brother@foobaz.com'],
                'Envelope recipients correctly relayed';
            my $expectedHeaders = join "\r\n",
                'Subject: Some message subject',
                'From: from@foobar.com',
                'To: another@foobaz.com',
                'Cc: brother@foobaz.com',
                '';
            is $toSMTPServerSent{headers}, $expectedHeaders,
                'Headers correctly relayed';
            my $expectedBody = join "\r\n",
                'Some message text',
                'More message text',
                '';
            is $toSMTPServerSent{body}, $expectedBody,
                'Body correctly relayed';

            $done->();
        }
    );
}
