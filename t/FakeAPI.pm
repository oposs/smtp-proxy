package FakeAPI;
use Mojo::Base -base, -signatures;
use Mojo::Promise;

has 'result';
has calledWith => sub { [] };

sub check ($self, $log, %args) {
    $log->debug('fake validation call');
    push @{$self->calledWith}, \%args;
    return Mojo::Promise->resolve($self->result);
}

sub clear {
    my $self = shift;
    @{$self->calledWith} = ();
}

1;
