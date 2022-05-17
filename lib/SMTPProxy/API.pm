package SMTPProxy::API;

use Mojo::Base -base;
use Mojo::JSON;
use Mojo::Promise;
use Mojo::UserAgent;
use Mojo::Util qw(dumper);

has [qw(log url)];

has ua => sub { Mojo::UserAgent->new };

sub check {
    my ($self, %args) = @_;
    return $self->ua->post_p($self->url, json => \%args)->then(sub {
        my $tx = shift;
        # $self->log->trace("Validation trace:",$tx->result->to_string);
        if ($tx->result->is_success) {
            return $tx->result->json;
        }
        $self->log->debug("Validation Failed:".dumper($tx->result->json));
        return Mojo::Promise->reject($tx->result->message);
    });
}

1;

__END__

=head1 NAME

SMTPProxy::API - calls the REST API to do authentication

=head1 SYNOPSIS

    use SMTPProxy::API;
    my $api = SMTPProxy::API->new(url => 'https://blah.service/v1/checkAuth');
    my $resultPromise = $api->check(
        username => '...',
        password => '...',
        from => 'blah@bar.com',
        to => ['x@baz.com', 'y@baz.com'],
        headers => [
            { name => 'To', value => 'foo@bar.com' },
            ...
        ])
    );
    $resultPromise->then(sub {
        my $result = shift;
        if ($result->{allow}) {
            say 'Allowed with headers:';
            for (@{$result->{headers}) {
                say '   ' . $_->{name} . ': ' . $_->{value};
            }
        }
        else {
            say 'Denied: ' . $result->{reason};
        }
    });

=head1 ATTRIBUTES

=head2 log

The C<Mojo::Log> object to use for logging.

=head2 url

The URL of the API endpoint to call.

=head1 METHODS

=head2 check()

Makes an asynchronous call to the API using the arguments passed. Will return
a C<Mojo::Promise> that will be resolved with the results of the API call if
it succeeds, or be rejected if there is a problem calling the API. Note that
the API returning that sending should be denied is a success case so far as
the call to the API goes.

=head1 COPYRIGHT

Copyright (c) 2018 by OETIKER+PARTNER AG. All rights reserved.

=head1 AUTHOR

S<Jonathan Worthington E<lt>jonathan@oetiker.chE<gt>>

=cut
