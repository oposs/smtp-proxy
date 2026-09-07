package SMTPProxy;

use Mojo::Base -base, -signatures;
use Mojo::Log;
use Mojo::Promise;
# Named below for its command id constants. Loaded explicitly rather than left
# to arrive as a side effect of RelayClient inheriting from it: that made this
# file compile only for as long as that inheritance happens to exist, and
# nothing here would have said so.
use Mojo::SMTP::Client ();
use SMTPProxy::RelayClient;
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
        # A transaction begins at MAIL and is abandoned by RSET, and neither
        # of those ends the session: it is possible to send several mails on
        # one connection, and RFC 4954 ties authentication to the session
        # rather than to the transaction, so the client is not asked to log in
        # again and the credentials it gave once have to outlive both.
        my $startTransaction = sub {
            %collected = (
                username => $collected{username},
                password => $collected{password},
            );
            return;
        };
        $connection->mail(sub ($from, $parameters) {
            $startTransaction->();
            $collected{from} = $from;
            $collected{mailParameters} = $parameters // [];
            return Mojo::Promise->resolve('got MAIL');
        });
        $connection->rcpt(sub ($to, $parameters) {
            # One entry per RCPT, in the order they arrived, rather than a map
            # keyed by address. The same recipient may legitimately be given
            # twice with different DSN parameters -- extra RCPTs are an
            # explicitly supported path -- and a map merges those two into
            # whichever came last, which RFC 3461 5.2.1 forbids and which turns
            # NOTIFY=NEVER into NOTIFY=SUCCESS rather than losing it.
            push @{$collected{recipients} //= []},
                { address => $to, parameters => $parameters // [] };
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
            $startTransaction->();
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
    my $recipients = $collected{recipients} // [];
    return $self->api->check($log,
        username => $collected{username},
        password => $collected{password},
        from => $collected{from},
        # `to` keeps its long standing shape, a flat list of addresses in the
        # order they were given. The parameters travel beside it, one entry per
        # RCPT, so an API that wants to see them can and one that does not is
        # unaffected.
        to => [map { $_->{address} } @$recipients],
        headers => $collected{headers},
        mailParameters => $collected{mailParameters},
        rcptParameters => $recipients
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
    my $smtp = SMTPProxy::RelayClient->new(
        address => $self->tohost,
        port => $self->toport,
        autodie => 1,
        log => $log,
    );
    my $last_ok_message = '';
    $smtp->inactivity_timeout(60); # relax :)
    # The response event carries a command id, so the test has to be against
    # one of those. CMD_DATA_END is the reply to the terminating dot, which is
    # where the upstream states that it has taken responsibility for the
    # message -- in production, its queue id.
    #
    # It used to compare against CMD_OK, which is a reply class rather than a
    # command id and happens to have the same numeric value as CMD_EHLO, so the
    # handler fired once per session on the EHLO reply and never on the one
    # that was wanted.
    $smtp->on(response => sub ($smtp, $cmd, $resp) {
        return unless $cmd == Mojo::SMTP::Client::CMD_DATA_END;
        $last_ok_message = $resp->message if $resp;
    });
    $smtp->send(
        from     => {
            address    => $apiResult->{from} || $mail{from},
            parameters => $mail{mailParameters},
        },
        # Already the shape RelayClient::_splitAddress consumes, so there is no
        # re-join by address here to get wrong.
        to       => $mail{recipients},
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
                # Mojo::SMTP::Client::Response::message caches into a field it
                # then forgets to return, so a second call on the same object
                # yields the empty string. Ask once.
                my $message = $resp->message;
                $log->debug("Upstream server says: $message ($last_ok_message)");
                $log->info('Relayed mail successfully for ' .
                    $clientAddress .
                    ( $apiResult && $apiResult->{authId} ? " using token $apiResult->{authId}" : " using no token"));
                # Defined-or was never the right test: the accumulator starts
                # as the empty string, which is defined, so the fallback could
                # not be reached even when nothing had been collected.
                $resultPromise->resolve(length($last_ok_message)
                    ? $last_ok_message : $message);
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
        ],
        # ESMTP parameters given on MAIL FROM, in the order received
        mailParameters => [
            { keyword => 'RET', value => 'HDRS' },
            ...
        ],
        # ESMTP parameters given on RCPT TO, one entry per RCPT command in
        # the order received, so a recipient repeated with different
        # parameters is reported as the two requests it was
        rcptParameters => [
            {
                address => 'x@baz.com',
                parameters => [
                    { keyword => 'NOTIFY', value => 'SUCCESS,FAILURE' },
                    ...
                ],
            },
            ...
        ])

A parameter given without a value, which RFC 5321 permits, has an undefined
C<value>. The RFC 3461 delivery status notification parameters (C<RET> and
C<ENVID> on MAIL, C<NOTIFY> and C<ORCPT> on RCPT) are relayed to the upstream
server, provided it announces the C<DSN> extension; see
L<SMTPProxy::RelayClient>. Other parameters are reported to the API but are
not relayed.

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
