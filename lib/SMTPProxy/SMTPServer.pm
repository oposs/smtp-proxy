package SMTPProxy::SMTPServer;

use Mojo::Base -base;
use Mojo::IOLoop;
use SMTPProxy::SMTPServer::Connection;

has [qw(address port tls_ca tls_cert tls_key)];

sub start {
    my ($self, $callback) = @_;
    Mojo::IOLoop->server(
        { address => $self->address, port => $self->port },
        sub {
            my ($loop, $stream, $id) = @_;
            my $connection = SMTPProxy::SMTPServer::Connection->new(
                loop => $loop,
                stream => $stream,
                id => $id
            );
            $callback->($connection);
            $connection->process;
        });
}

1;

__END__

=head1 NAME

SMTPProxy::SMTPServer - an async SMTP server using Mojo::IOLoop

=head1 SYNOPSIS

    use SMTPProxy::SMTPServer;
    my $server = SMTPProxy->new(
        address => '0.0.0.0',
        port => 1234,
        tls_ca => 'path/to/ca.crt',
        tls_cert => 'path/to/server.crt',
        tls_key => 'path/to/server.key'
    );
    $server->start(sub {
        my $connection = shift;
        $connection->auth_plain(sub {
            my ($authzid, $authcid, $password) = @_;
            # Check and then resolve or reject
            return Mojo::Promise->resolve;
        });
        $connection->mail(sub {
            my ($from, $parameters) = @_;
            # Do something with these, return Promise.
            return Mojo::Promise->new->resolve;
        });
        $connection->to(sub {
            my ($rcpt, $parameters) = @_;
            # Do something with these, return Promise.
            return Mojo::Promise->new->resolve;
        });
        $connection->data(sub {
            my ($headersPromise, $bodyPromise) = @_;
            my $result = Promise->new;
            $headersPromise->then(sub {
                # Deal with headers part of message
            });
            $bodyPromise->then(sub {
                # Deal with body part of message, then resolve the result
                # Promise in order to accept (or reject it to deny sending).
                $result->resolve;
            });
        });
        $connection->vrfy(sub {
            return Promise->new->reject(553, 'User ambiguous');
        });
        $connection->rset(sub {
            return Promise->new->resolve;
        });
        $connection->quit(sub {
            return Promise->new->resolve;
        });
    });

=head1 ATTRIBUTES

=head2 address

Address for the server to listen on.

=head2 port

Port for the server to listen on.

=head2 tls_ca

The CA certificate for use with StartTLS.

=head2 tls_cert

The server certificate for use with StartTLS.

=head2 tls_key

The server key for use with StartTLS.

=head1 METHODS

=head1 COPYRIGHT

Copyright (c) 2018 by OETIKER+PARTNER AG. All rights reserved.

=head1 AUTHOR

S<Jonathan Worthington E<lt>jonathan@oetiker.chE<gt>>

=cut
