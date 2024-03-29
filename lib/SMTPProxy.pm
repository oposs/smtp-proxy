package SMTPProxy;

use Mojo::Base -base, -signatures;
use Mojo::Log;
use Mojo::Promise;
use Mojo::SMTP::Client;
use SMTPProxy::SMTPServer;
use Mojo::Util qw(dumper);

has [qw(
    listen tohost toport user tls_cert tls_key api service_name
    smtplog credentials
)];

has log => sub ($self) {
    Mojo::Log->new(
        path => $self->{logpath} || '/dev/stderr',
        level => $self->{loglevel} || 'trace',
    );
};

sub setup ($self) {
    #warn dumper $self;
    my $server = SMTPProxy::SMTPServer->new(
        log => $self->log,
        listen => $self->listen,
        tls_cert => $self->tls_cert,
        tls_key => $self->tls_key,
        service_name => ( $self->service_name || 'smtp-proxy'),
        smtplog => $self->smtplog,
        credentials => $self->credentials,
        require_starttls => 1,
        require_auth => 1,
        timeout => 0,
    );
    $server->setup(sub ($connection) {
        # State the proxy collects to send to the API and target mail
        # server.
        my %collected;
        my $clientAddress = $connection->clientAddress;
        my $log = $connection->log;
        $connection->auth(sub ($authzid, $authcid, $password) {
            $collected{username} = $authcid;
            $collected{password} = $password;
            return Mojo::Promise->resolve;
        });
        $connection->mail(sub ($from, $parameters) {

            # reset the collected data except for authentication.
            # note, it is possible to send multiple mails per connction!
            %collected = (
                username => $collected{username},
                password => $collected{password},
            );
            $collected{from} = $from;
            return Mojo::Promise->resolve('got MAIL');
        });
        $connection->rcpt(sub ($to, $parameters) {
            push @{$collected{to} //= []}, $to;
            return Mojo::Promise->resolve('got RCPT');
        });
        $connection->data(sub ($headersPromise, $bodyPromise) {
            my $result = Mojo::Promise->new;
            my $apiResult;
            $headersPromise->then(sub ($headers){
                $collected{headers} = [
                    map {
                        if (/^([^:]+):\s*(.+)$/s) {
                            { name => $1, value => $2 }
                        }
                        else {
                            $log->warn("Could not parse header '$_'");
                            ()
                        }
                    } split /\r\n(?=$|\S)/, $headers
                ];
                $apiResult = $self->_callAPI($log,%collected);
                return;
            })->catch(sub {
                my $msg = shift;
                $log->error("Unexpecteldly failed HeadersPromise: $msg");
                $result->reject($msg);
            });
            $bodyPromise->then(sub ($body) {
                $collected{body} = $body;
                return $apiResult->then(
                    sub {
                        my $outcome = shift;
                        if ($outcome->{allow}) {
                            $log->debug("Relaying Mail to upstream SMTP Server");
                            $self->_relayMail($log,$result, $clientAddress,
                                $outcome, %collected);
                            return;
                        }
                        else {
                            my $reason = $outcome->{reason};
                            $log->info("Mail rejected by API ($reason) for " .
                                $clientAddress);
                            $log->debug("INPUT $_") for split /\n/, dumper({%collected,exists $collected{password} ? ( password => '*******' ) : (), exists $collected{body} ? ( body => '...' ): ()} );
                            $result->reject($reason);
                            return;
                        }
                    },
                    sub {
                        my $error = shift;
                        $log->warn("Failed to call API ($error) for " .
                            $clientAddress);
                        $result->reject('authentication service failed');
                        return;
                    }
                );
            })->catch(sub {
                my $msg = shift;
                $log->error("Unexpecteldly failed BodyPromise: $msg");
                $result->reject($msg);
            });
            return $result;
        });
        $connection->vrfy(sub {
            return Mojo::Promise->reject('Unimplemented');
        });
        $connection->rset(sub {
            %collected = ();
        });
    });
    $self->_dropPrivs if $self->user;
}

sub _dropPrivs ($self) {
    my $user = $self->user;
    my ($uid, $gid) = (getpwnam $user)[2, 3];
    die "Cannot resolve username '$user': $!" unless $uid && $gid;
    POSIX::setgid($gid) or die "Failed to setgid to $gid: $!";
    POSIX::setuid($uid) or die "Failed to setuid to $uid: $!";
    $self->log->info("Dropped privileges to user $user");
}

sub _callAPI ($self,$log, %collected) {
    $log->debug('Making call to auth/headers API');
    return $self->api->check($log,
        username => $collected{username},
        password => $collected{password},
        from => $collected{from},
        to => $collected{to},
        headers => $collected{headers}
    );
}

sub _relayMail ($self,$log, $resultPromise, $clientAddress, $apiResult, %mail) {
    # We should:
    # * Remove headers that the API headers result sets to undef/null
    # * Replace headers that the API headers result provides a value for
    # * Add any new headers
    # We roll all of these into two steps:
    # 1. Remove all existing headers mentioned by the API result
    # 2. Add all headers from the API result with a defined value
    my @headers = @{$mail{headers}};
    my @apiHeaders = @{$apiResult->{headers}};
    my %toRemove = map { $_->{name} => 1 } @apiHeaders;
    @headers = grep { not $toRemove{$_->{name}} } @headers;
    push @headers, grep { defined $_->{value} } @apiHeaders;

    my $formattedHeaders = join '',
        map { $_->{name} . ': ' . $_->{value} . "\r\n" } @headers;
    my $smtp = Mojo::SMTP::Client->new(
        address => $self->tohost,
        port => $self->toport,
        autodie => 1,
    );
    my $last_ok_message = '';
    $smtp->inactivity_timeout(60); # relax :)
    my $first_ok_skip;
    $smtp->on(response => sub ($smtp, $cmd, $resp) {
        if ($cmd == Mojo::SMTP::Client::CMD_OK) {
           # and after first response others should be fast enough
           $last_ok_message = $resp if $resp and $first_ok_skip;
           $first_ok_skip = 1;
        }
    });
    $smtp->send(
        from     => $apiResult->{from} || $mail{from},
        to       => $mail{to},
        data     => $formattedHeaders . "\r\n" . $mail{body},
        quit     => 1,
        sub {
            my ($smtp, $resp) = @_;
            my $error = $resp->error;
            if ($error) {
                $log->info("Mail refused by relay server ($error) for " .
                    $clientAddress);
                $log->debug("Mail $_") for split /\n/, dumper({%mail, exists $mail{password} ? (password  => '*****') : (), body => '...'});
                $log->debug("ApiResult $_") for split /\n/, dumper($apiResult);
                return $resultPromise->reject($error);
            }
            else {
                $log->debug("Upstream server says: ".$resp->message. " ($last_ok_message)");
                $log->info('Relayed mail successfully for ' .
                    $clientAddress .
                    ( $apiResult && $apiResult->{authId} ? " using token $apiResult->{authId}" : " using no token"));
                $resultPromise->resolve($last_ok_message // $resp->message);
            }
        }
    );
    return;
}

1;

__END__

=head1 NAME

SMTPProxy - SMTP proxy using an API to authenticate and inject headers

=head1 SYNOPSIS

    use SMTPProxy;
    my $proxy = SMTPProxy->new(
        # Where to start an SMTP server
        listen => [ 'ip:port', ... ],
        # The SMTP server to proxy accepted requests onward to
        tohost => ...,
        toport => ...,
        # TLS cert and key files so we can do STARTTLS
        tls_cert => ...,
        tls_key => ...,
        # Object that calls to the auth/headers API asynchronously
        api => ...,
        # Optionally, the user to run as (dropped to after port binding)
        user => ...,
        # Optionally, the service name to use in the SMTP greeting (will
        # take listenhost as the default)
        service_name => ...,
        # A log object
        log => ...,
    );
    $proxy->run;

=head1 ATTRIBUTES

=head2 log

The C<Mojo::Log> object to use for logging.

=head2 listenhost

The host to listen for incoming connections on.

=head2 listenport

The port to listen for incoming connections on.

=head2 tohost

The host of the target SMTP server to send mail to.

=head2 toport

The port of the target SMTP server to send mail to.

=head2 tls_cert

Path to a certificate file that can be used for STARTTLS.

=head2 tls_key

Path to a key file that can be used for STARTTLS.

=head2 api

An object having a method `check`, which will be called like this:

    $self->api->check(
        username => '...',
        password => '...',
        from => 'blah@bar.com',
        to => ['x@baz.com', 'y@baz.com'],
        headers => [
            { name => 'To', value => 'foo@bar.com' },
            ...
        ])

And will return a C<Mojo::Promise> that will resolve to a hashref like either:

    {
        allow => 0,
        reason => "Authentication failed"
    }

Or:

    {
        allow => 1,
        headers => [
            { name => "Sender", value => "bar@blah.com" }
        ]
    }

=head2 user

Optional user to run as after port binding.

=head2 service_name

The name of the service, to be used in SMTP greetings.

=head1 METHODS

=head2 setup()

Sets up the proxy. Relies on the caller to start (or have started) the
C<Mojo::IOLoop>.

=head1 COPYRIGHT

Copyright (c) 2018 by OETIKER+PARTNER AG. All rights reserved.

=head1 AUTHOR

S<Jonathan Worthington E<lt>jonathan@oetiker.chE<gt>>

=cut
