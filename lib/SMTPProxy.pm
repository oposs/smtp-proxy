package SMTPProxy;

use Mojo::Base -base;
use Mojo::Log;
use Mojo::Promise;
use SMTPProxy::SMTPServer;

has [qw(listenhost listenport tohost toport user tls_cert tls_key api service_name)];

has log => sub {
    my $self = shift;
    Mojo::Log->new(
        path => $self->{logpath} || '/dev/stderr',
        level => $self->{loglevel} || 'debug',
    );
};

sub run {
    my $self = shift;
    my $server = SMTPProxy::SMTPServer->new(
        log => $self->log,
        address => $self->listenhost,
        port => $self->listenport,
        tls_cert => $self->tls_cert,
        tls_key => $self->tls_key,
        service_name => $self->service_name || $self->listenhost,
        require_starttls => 1,
        require_auth => 1,
    );
    $server->start(sub {
        my $connection = shift;

        # State the proxy collects to send to the API and target mail
        # server.
        my %collected;

        $connection->auth_plain(sub {
            my ($authzid, $authcid, $password) = @_;
            $collected{username} = $authcid;
            $collected{password} = $password;
            return Mojo::Promise->new->resolve;
        });
        $connection->mail(sub {
            my ($from, $parameters) = @_;
            $collected{from} = $from;
            return Mojo::Promise->new->resolve;
        });
        $connection->rcpt(sub {
            my ($to, $parameters) = @_;
            push @{$collected{to} //= []}, $to;
            return Mojo::Promise->new->resolve;
        });
        $connection->data(sub {
            my ($headersPromise, $bodyPromise) = @_;
            my $result = Mojo::Promise->new;
            my $apiResult;
            $headersPromise->then(sub {
                my $headers = shift;
                $collected{headers} = $headers;
                $apiResult = $self->_callAPI(%collected);
            });
            $bodyPromise->then(sub {
                $collected{body} = shift;
                $self->_relayMail($result, %collected);
            });
            return $result;
        });
        $connection->vrfy(sub {
            return Mojo::Promise->new->reject('Unimplemented');
        });
        $connection->rset(sub {
            %collected = ();
        });
        $connection->quit(sub {
            # XXX
        });
    });
}

sub _callAPI {
    my ($self, %collected) = @_;
    my @headers = map {
        /^(.+):\s*(.+)$/;
        { name => $1, value => $2 }
    } split /\r\n/, $collected{headers};
    return $self->api->check(
        username => $collected{username},
        password => $collected{password},
        from => $collected{from},
        to => $collected{to},
        headers => \@headers
    );
}

sub _relayMail {
    my ($self, $resultPromise, %mail) = @_;
    my $smtp = Mojo::SMTP::Client->new(
        address => $self->tohost,
        port => $self->toport,
        autodie => 1,
    );
    $smtp->send(
        from     => $mail{from},
        to       => $mail{to},
        data     => $mail{headers} . "\r\n" . $mail{body},
        quit     => 1,
        sub {
            my ($smtp, $resp) = @_;
            $resultPromise->resolve;
        });
}

1;

__END__

=head1 NAME

SMTPProxy - SMTP proxy using an API to authenticate and inject headers

=head1 SYNOPSIS

    use SSLProxy;
    my $proxy = SSLProxy->new(
        # Where to start an SMTP server
        listenhost => ...,
        listenport => ...,
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

And will return a C<Mojo::Promise> that will resolve to an hash like either:

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
