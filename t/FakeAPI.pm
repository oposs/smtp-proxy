package FakeAPI;
use Mojo::Base -base;
use Mojo::Promise;

has 'result';
has calledWith => sub { [] };

sub check {
    my ($self, %args) = @_;
    push @{$self->calledWith}, \%args;
    return Mojo::Promise->new->resolve($self->result);
}

sub clear {
    my $self = shift;
    @{$self->calledWith} = ();
}

1;
