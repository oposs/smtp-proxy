package SMTPProxy::SMTPServer::Connection;

use Mojo::Base -base;

has [qw(loop stream id auth_plain mail to data vrfy rset quit)];

sub process {
    my $self = shift;
    Mojo::IOLoop->remove($self->id);
}

1;

__END__

=head1 NAME

SMTPProxy::SMTPServer::Connection - connection object for SMTPProxy::SMTPServer

=head1 DESCRIPTION

Connection object for C<SMTPProxy::SMTPServer>; see its documentation for
further details.

=head1 COPYRIGHT

Copyright (c) 2018 by OETIKER+PARTNER AG. All rights reserved.

=head1 AUTHOR

S<Jonathan Worthington E<lt>jonathan@oetiker.chE<gt>>

=cut
