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

plan tests => 30;

# Test infrastructure

my $TEST_HOST = '127.0.0.1';
my $TEST_PROXY_PORT = Mojo::IOLoop::Server->generate_port;
my $TEST_TO_PORT = Mojo::IOLoop::Server->generate_port;
my $TEST_LOG = Mojo::Log->new(level => 'error');

my $testApi = FakeAPI->new;
my %toSMTPServerSent;
my $fakeServerError;
sub setupTestSMTPTarget {
    my $server = SMTPProxy::SMTPServer->new(
        log => $TEST_LOG,
        address => $TEST_HOST,
        port => $TEST_TO_PORT,
        service_name => 'test.to.service',
        require_starttls => 0,
        require_auth => 0,
    );
    $server->setup(sub {
        my $connection = shift;
        $connection->auth(sub {
            my ($authzid, $authcid, $password) = @_;
            fail "Target SMTP server should not be auth'd";
            return Mojo::Promise->reject;
        });
        $connection->mail(sub {
            my ($from, $parameters) = @_;
            $toSMTPServerSent{from} = $from;
            return $fakeServerError
                ? Mojo::Promise->new->reject($fakeServerError)
                : Mojo::Promise->new->resolve;
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
    $proxy->setup;
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
    $fakeServerError = '';
    $test->(@rest
        ? sub { runOneTestCase(@rest) }
        : sub { Mojo::IOLoop->stop });
}

# Tests

runTestCases(\&allowedSimple, \&denied, \&allowedInsertHeaders, \&relayError,
    \&transparency, \&allowedChangeFrom, \&allowedChangeHeaders, \&loginAuth);

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

            my @calls = @{$testApi->calledWith};
            is scalar(@calls), 1, 'Made a single call to the API';
            is $calls[0]->{username}, 'fooser', 'Correct username sent to API';
            is $calls[0]->{password}, 's3cr3t', 'Correct password sent to API';
            is $calls[0]->{from}, 'sender@foobar.com', 'Correct to sent to API';
            is_deeply $calls[0]->{to},
                ['another@foobaz.com', 'brother@foobaz.com'],
                'Correct to sent to API';
            is_deeply $calls[0]->{headers},
                [
                    { name => 'Subject', value => 'Some message subject' },
                    { name => 'From', value => 'from@foobar.com' },
                    { name => 'To', value => 'another@foobaz.com' },
                    { name => 'Cc', value => 'brother@foobaz.com' },
                ],
                'Correct headers sent to API';

            $done->();
        }
    );
}

sub denied {
    my $done = shift;

    $testApi->result({
        allow => 0,
        reason => 'bad username or password'
    });

    my $smtp = Mojo::SMTP::Client->new(
        address => $TEST_HOST,
        port => $TEST_PROXY_PORT,
        autodie => 1,
        tls_verify => 0,
    );
    $smtp->send(
        starttls => 1,
        auth     => {login => 'fuser', password => 's3cr3t'},
        from     => 'sender@foobar.com',
        to       => 'another@foobaz.com',
        data     => join("\r\n",
                        'Subject: Some message subject',
                        'From: from@foobar.com',
                        'To: another@foobaz.com',
                        '',
                        'Some message text',
                        'More message text'),
        quit     => 1,
        sub {
            my ($smtp, $resp) = @_;
            ok($resp->error, 'Mail not accepted by proxy');
            like $resp->error, qr/bad username or password/,
                'Error text returned from API is sent onwards';
            ok !defined($toSMTPServerSent{from}), 'Did not relay mail';
            $done->();
        }
    );
}

sub allowedInsertHeaders {
    my $done = shift;

    $testApi->result({
        allow => 1,
        headers => [
            { name => 'Sender', value => 'sender@foobar.com' },
            { name => 'X-Parrot', value => 'Norwegian blue' },
        ]
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
        to       => ['another@foobaz.com'],
        data     => join("\r\n",
                        'Subject: Some message subject',
                        'From: from@foobar.com',
                        'To: another@foobaz.com',
                        '',
                        'Some message text',
                        'More message text'),
        quit     => 1,
        sub {
            my ($smtp, $resp) = @_;
            ok(!($resp->error), 'Allowed mail accepted by proxy');
            my $expectedHeaders = join "\r\n",
                'Subject: Some message subject',
                'From: from@foobar.com',
                'To: another@foobaz.com',
                'Sender: sender@foobar.com',
                'X-Parrot: Norwegian blue',
                '';
            is $toSMTPServerSent{headers}, $expectedHeaders,
                'Headers relayed include those added by the API';
            $done->();
        }
    );
}

sub relayError {
    my $done = shift;

    $testApi->result({
        allow => 1,
        headers => []
    });
    $fakeServerError = "Sorry, I don't send from there";

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
            ok($resp->error, 'Mail did not send due to relay server rejection');
            is $toSMTPServerSent{from}, 'sender@foobar.com',
                'Really did try to call relay server';
            like $resp->error, qr/Sorry, I don't send from there/,
                'Error text returned from relay server is sent onwards';
            $done->();
        }
    );
}

sub transparency {
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
        to       => ['another@foobaz.com'],
        data     => join("\r\n",
                        'Subject: Some message subject',
                        'From: from@foobar.com',
                        'To: another@foobaz.com',
                        '',
                        'Some message text before . line',
                        '.',
                        'More message text after . line'),
        quit     => 1,
        sub {
            my ($smtp, $resp) = @_;
            ok(!($resp->error), 'Mail with lone . line in body accepted by proxy');
            my $expectedBody = join "\r\n",
                'Some message text before . line',
                '.',
                'More message text after . line',
                '';
            is $toSMTPServerSent{body}, $expectedBody,
                'Body with a line . line correctly relayed';
            $done->();
        }
    );
}

sub allowedChangeFrom {
    my $done = shift;

    $testApi->result({
        allow => 1,
        headers => [],
        from => 'different@foobar.com'
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
        to       => ['another@foobaz.com'],
        data     => join("\r\n",
                        'Subject: Some message subject',
                        'From: from@foobar.com',
                        'To: another@foobaz.com',
                        '',
                        'Some message text',
                        'More message text'),
        quit     => 1,
        sub {
            my ($smtp, $resp) = @_;
            ok(!($resp->error), 'Allowed mail accepted by proxy');
            is $toSMTPServerSent{from}, 'different@foobar.com',
                'Mail used the replacement `from` returned by the API';
            my $expectedHeaders = join "\r\n",
                'Subject: Some message subject',
                'From: from@foobar.com',
                'To: another@foobaz.com',
                '';
            is $toSMTPServerSent{headers}, $expectedHeaders,
                'Headers left as is, as not returned by the API';
            $done->();
        }
    );
}

sub allowedChangeHeaders {
    my $done = shift;

    $testApi->result({
        allow => 1,
        headers => [
            { name => 'X-GoAway', value => undef },
            { name => 'X-ReplaceMe', value => 'a new header' },
            { name => 'X-ReplaceMe', value => 'another new header' },
        ]
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
        to       => ['another@foobaz.com'],
        data     => join("\r\n",
                        'Subject: Some message subject',
                        'X-GoAway: this will be removed',
                        'X-ReplaceMe: this will be replaced',
                        'X-ReplaceMe: this will also be replaced',
                        'From: from@foobar.com',
                        'To: another@foobaz.com',
                        '',
                        'Some message text',
                        'More message text'),
        quit     => 1,
        sub {
            my ($smtp, $resp) = @_;
            ok(!($resp->error), 'Allowed mail accepted by proxy');
            my $expectedHeaders = join "\r\n",
                'Subject: Some message subject',
                'From: from@foobar.com',
                'To: another@foobaz.com',
                'X-ReplaceMe: a new header',
                'X-ReplaceMe: another new header',
                '';
            is $toSMTPServerSent{headers}, $expectedHeaders,
                'Headers removed/replaced as the API requested';
            $done->();
        }
    );
}

sub loginAuth {
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
        auth     => {type => 'login', login => 'fooser', password => 's3cr3t'},
        from     => 'sender@foobar.com',
        to       => ['another@foobaz.com', 'brother@foobaz.com'],
        data     => join("\r\n",
                        'Subject: Some message subject',
                        'From: from@foobar.com',
                        'To: another@foobaz.com',
                        '',
                        'Some message text',
                        'More message text'),
        quit     => 1,
        sub {
            my ($smtp, $resp) = @_;
            ok(!($resp->error), 'Allowed mail accepted by proxy using login auth');

            my @calls = @{$testApi->calledWith};
            is scalar(@calls), 1, 'Made a single call to the API';
            is $calls[0]->{username}, 'fooser',
                'Correct username sent to API using login auth';
            is $calls[0]->{password}, 's3cr3t',
                'Correct password sent to API using login auth';

            $done->();
        }
    );
}
