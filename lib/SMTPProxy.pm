package SMTPProxy;

use Mojo::Base -base;
use Mojo::Log;
use SMTPProxy::SMTPServer;

has [qw(listenhost listenport tohost toport user tls_cert tls_key api service_name)];

sub setup {
    say "todo";
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
        # Object that calls to the API asynchronously
        api => ...,
        # Optionally, the user to run as (dropped to after port binding)
        user => ...,
        # Optionally, the service name to use in the SMTP greeting (will
        # take listenhost as the default)
        service_name => ...,
    );
    $proxy->run;

=head1 ATTRIBUTES

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

And will return a Promise that will resolve to an hash like either:

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
