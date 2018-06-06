package FakeAPI;
use Mojo::Base -base;

has 'result';
has calledWith => sub { [] };

sub check {
    my ($self, %args) = @_;
    push @{$self->calledWith}, \%args;
}

sub clear {
    my $self = shift;
    @{$self->calledWith} = ();
}

1;
