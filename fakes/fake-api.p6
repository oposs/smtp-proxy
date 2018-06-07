use Cro::HTTP::Router;
use Cro::HTTP::Server;

my $application = route {
    post -> {
        request-body -> %body {
            dd %body;
#            content 'application/json', { allow => 1, headers => [] }
            content 'application/json', { allow => 0, reason => 'Weather too hot to email' }
        }
    }
}

Cro::HTTP::Server.new(:$application, :port(20000)).start;
sleep;
