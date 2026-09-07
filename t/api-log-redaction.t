use FindBin;
use lib "$FindBin::Bin";
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../thirdparty/lib/perl5";
use strict;
use warnings;
use Mojo::Base -strict, -signatures;

use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Mojo::IOLoop::Server;
use Mojo::Log;
use Mojo::Server::Daemon;
use Mojolicious;
use SMTPProxy::API;
use Test::More;

# The SMTP password travels to the auth API as an ordinary request argument.
# When that call comes back with anything other than a 2xx, the API client
# dumps the request it made so an operator can see what was rejected -- and
# that dump used to include the password in the clear. It lands in the main
# --logpath log, which is not the --credentials-gated smtplog, so the leak sits
# outside the containment boundary the design draws around credentials. The
# default log level is debug, so this is the stock configuration, not a
# diagnostic one somebody had to turn on.

plan tests => 6;

my $PASSWORD = 'Sup3rSecretPassw0rd';

my $logDir = tempdir(CLEANUP => 1);
my $logFile = "$logDir/proxy.log";
my $log = Mojo::Log->new(path => $logFile, level => 'debug');

# An API that fails every call, which is the branch that dumps the request.
my $port = Mojo::IOLoop::Server->generate_port;
my $app = Mojolicious->new;
$app->log->level('fatal');
$app->routes->post('/checkAuth' => sub ($c) {
    $c->render(status => 500, json => {error => 'internal error'});
});
my $daemon = Mojo::Server::Daemon->new(
    app    => $app,
    listen => ["http://127.0.0.1:$port"],
    silent => 1,
);
$daemon->start;

my $api = SMTPProxy::API->new(url => "http://127.0.0.1:$port/checkAuth");

my $rejected;
$api->check($log,
    username => 'testuser',
    password => $PASSWORD,
    from     => 'sender@example.com',
    to       => ['recipient@example.com'],
    headers  => [{name => 'Subject', value => 'hello'}],
)->then(sub { fail 'The API call should have been rejected' })
 ->catch(sub ($err) { $rejected = $err })
 ->wait;

ok defined $rejected, 'A non-2xx API response rejects the promise';

my $logged = path($logFile)->slurp;

unlike $logged, qr/\Q$PASSWORD\E/,
    'No plaintext password reaches the main log';
like $logged, qr/Validation Failed/,
    'The failed validation is still reported';
like $logged, qr/password/,
    'The password field is still shown as having been sent';
like $logged, qr/\*\*\*\*\*/,
    'The password value is replaced with a redaction marker';

# The rest of the request is what makes the dump worth having, so it must
# survive the redaction.
like $logged, qr/testuser/,
    'The username is still logged, so the dump remains diagnostic';
