package SMTPProxy::SMTPServer;

use Mojo::Base -base;
use Mojo::IOLoop;
use SMTPProxy::SMTPServer::Connection;

has [qw(
    address port log tls_cert tls_key service_name require_starttls require_auth
    timeout smtplog credentials
)];

sub setup {
    my ($self, $callback) = @_;
    my $smtplogHandle;
    if ($self->smtplog) {
        my $file = $self->smtplog;
        open($smtplogHandle, '>>', $file) or die "Could not open $file: $!";
    }
    Mojo::IOLoop->server(
        { address => $self->address, port => $self->port },
        sub {
            my ($loop, $stream, $id) = @_;

            $stream->timeout($self->timeout) if defined $self->timeout;
            my $handle = $stream->handle;
            my $clientAddress = $handle->peerhost . ':' . $handle->peerport;
            $self->log->debug("New incoming connection from $clientAddress");

            my $connection = SMTPProxy::SMTPServer::Connection->new(
                loop => $loop,
                stream => $stream,
                id => $id,
                server => $self,
                clientAddress => $clientAddress,
                smtplogHandle => $smtplogHandle,
            );
            $callback->($connection);
            $connection->process;
            $self->log->debug("Starting processing of request for $clientAddress");
        });
}

1;

__END__

=head1 NAME

SMTPProxy::SMTPServer - an async SMTP server using Mojo::IOLoop

=head1 SYNOPSIS

    use SMTPProxy::SMTPServer;
    my $server = SMTPProxy::SMTPServer->new(
        log => $some-mojo-log-object,
        address => '0.0.0.0',
        port => 1234,
        tls_cert => 'path/to/server.crt',
        tls_key => 'path/to/server.key',
        service_name => 'host.to.use.in.greeting.com',
        require_starttls => 1,
        require_auth => 1,
    );
    $server->setup(sub {
        my $connection = shift;
        $connection->auth(sub {
            my ($authzid, $authcid_or_username, $password) = @_;
            # Check and then resolve or reject
            return Mojo::Promise->resolve;
        });
        $connection->mail(sub {
            my ($from, $parameters) = @_;
            # Do something with these, return Promise.
            return Mojo::Promise->new->resolve;
        });
        $connection->rcpt(sub {
            my ($to, $parameters) = @_;
            # Do something with these, return Promise.
            return Mojo::Promise->new->resolve;
        });
        $connection->data(sub {
            my ($headersPromise, $bodyPromise) = @_;
            my $result = Mojo::Promise->new;
            $headersPromise->then(sub {
                # Deal with headers part of message
            });
            $bodyPromise->then(sub {
                # Deal with body part of message, then resolve the result
                # Promise in order to accept (or reject it to deny sending).
                $result->resolve;
            });
            return $result;
        });
        $connection->vrfy(sub {
            return Mojo::Promise->new->reject('User ambiguous');
        });
        $connection->rset(sub {
            # Nothing async happens here, so return value ignored
        });
        $connection->quit(sub {
            # Nothing async happens here, so return value ignored
        });
    });

=head1 ATTRIBUTES

=head2 address

Address for the server to listen on.

=head2 port

Port for the server to listen on.

=head2 log

An instance of C<Mojo::Log> or something with an equivalent API, for logging.

=head2 tls_ca

The CA certificate for use with StartTLS.

=head2 tls_cert

The server certificate for use with StartTLS.

=head2 tls_key

The server key for use with StartTLS.

=head2 service_name

The name of the service, to be used in the handshake.

=head2 require_starttls

Whether to enforce STARTTLS is used.

=head2 require_auth

Whether to enforce that authentication takes place.

=head1 METHODS

=head2 setup()

Sets up the SMTP server. Relies on the caller to start (or have started) the
C<Mojo::IOLoop>.

=head1 COPYRIGHT

Copyright (c) 2018 by OETIKER+PARTNER AG. All rights reserved.

=head1 AUTHOR

S<Jonathan Worthington E<lt>jonathan@oetiker.chE<gt>>

=cut
