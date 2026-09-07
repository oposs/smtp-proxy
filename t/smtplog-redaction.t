use FindBin;
use lib "$FindBin::Bin";
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../thirdparty/lib/perl5";
use strict;
use warnings;
use Mojo::Base -strict, -signatures;

use File::Temp qw(tempdir);
use MIME::Base64 qw(encode_base64);
use Mojo::File qw(path);
use Mojo::IOLoop;
use Mojo::IOLoop::Server;
use Mojo::Log;
use Mojo::Promise;
use RawSMTPClient;
use SMTPProxy::SMTPServer;
use Test::More;

# --credentials is the documented switch that decides whether usernames and
# passwords reach the smtplog. Without it the AUTH argument must be redacted,
# whatever case the client spelled the verb and the mechanism in: RFC 4954
# section 2 makes both case insensitive, so a redaction anchored on the literal
# "AUTH" wrote the base64 authcid/password straight to the file.

plan tests => 8;

my $PASSWORD = 'Sup3rSecretPassw0rd';
my $TOKEN = encode_base64("\0testuser\0$PASSWORD", '');

my $logDir = tempdir(CLEANUP => 1);
my $smtplog = "$logDir/smtp.log";

my $TEST_HOST = '127.0.0.1';
my $TEST_PORT = Mojo::IOLoop::Server->generate_port;

my $server = SMTPProxy::SMTPServer->new(
    log => Mojo::Log->new(level => $ENV{TEST_LOG_LEVEL} // 'warn'),
    listen => [$TEST_HOST . ':' . $TEST_PORT],
    service_name => 'test.service.name',
    require_starttls => 0,
    require_auth => 0,
    smtplog => $smtplog,
    credentials => 0,
);
$server->setup(sub ($connection) {
    $connection->auth(sub { Mojo::Promise->resolve });
    $connection->mail(sub { Mojo::Promise->resolve });
    $connection->rcpt(sub { Mojo::Promise->resolve });
    $connection->data(sub { Mojo::Promise->resolve });
});

# Each spelling gets its own connection, since a successful AUTH moves the
# session on. The last one is a line the parser rejects outright, which must
# still not be logged in the clear.
my @spellings = (
    ['AUTH PLAIN', "AUTH PLAIN $TOKEN"],
    ['auth plain', "auth plain $TOKEN"],
    ['Auth Plain', "Auth Plain $TOKEN"],
    ['malformed',  "AUTH PLAIN $TOKEN\rjunk"],
);

my %reply;
my $run;
$run = sub ($index) {
    if ($index > $#spellings) {
        Mojo::IOLoop->stop;
        return;
    }
    my ($desc, $line) = @{$spellings[$index]};
    my $client = RawSMTPClient->new(address => $TEST_HOST, port => $TEST_PORT);
    $client->connect_p
        ->then(sub { $client->command_p('EHLO client.example.com') })
        ->then(sub { $client->command_p($line) })
        ->then(sub ($r) { $reply{$desc} = $r; $client->close; return })
        ->catch(sub ($err) { fail "$desc session failed: $err" })
        ->finally(sub { $run->($index + 1) });
};
Mojo::IOLoop->next_tick(sub { $run->(0) });
Mojo::IOLoop->start;

# All three well-formed spellings are accepted, so all three are a live path to
# the log. The fourth is rejected, which is what makes it worth checking.
like $reply{'AUTH PLAIN'}, qr/^235 /, 'Uppercase AUTH PLAIN authenticates';
like $reply{'auth plain'}, qr/^235 /, 'Lowercase auth plain authenticates';
like $reply{'Auth Plain'}, qr/^235 /, 'Mixed case Auth Plain authenticates';
like $reply{malformed}, qr/^500 /, 'A malformed AUTH line is rejected';

my $logged = path($smtplog)->slurp;
unlike $logged, qr/\Q$TOKEN\E/, 'No AUTH token reaches the smtplog';
unlike $logged, qr/\Q$PASSWORD\E/, 'No plaintext password reaches the smtplog';
like $logged, qr/\[REDACTED\]/, 'The AUTH argument is redacted';

# The verb and mechanism are still logged, so an operator can see what happened.
like $logged, qr/auth plain \[REDACTED\]/, 'Lowercase AUTH is logged, redacted';
