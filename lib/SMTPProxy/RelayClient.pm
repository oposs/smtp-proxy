package SMTPProxy::RelayClient;

use Mojo::Base 'Mojo::SMTP::Client', -signatures;
use Scalar::Util qw(weaken);

# Mojo::SMTP::Client writes a bare 'MAIL FROM:<...>' and 'RCPT TO:<...>' with
# no way to append ESMTP parameters, so the DSN parameters the client gave us
# would be dropped on the floor. This subclass takes an address either as a
# plain string, as before, or as a hashref:
#
#     { address => 'a@b.com', parameters => [{ keyword => 'NOTIFY', value => 'NEVER' }] }
#
# Only the RFC 3461 parameters are relayed, and only to an upstream that
# announced DSN in its EHLO response. Other ESMTP parameters are left alone
# because the proxy does not negotiate them with the upstream.

my %MAIL_DSN_KEYWORDS = map { $_ => 1 } qw(RET ENVID);
my %RCPT_DSN_KEYWORDS = map { $_ => 1 } qw(NOTIFY ORCPT);

has 'log';

sub new {
    my $self = shift->SUPER::new(@_);
    $self->on(response => sub ($self, $cmd, $resp) {
        return unless $cmd == Mojo::SMTP::Client::CMD_EHLO;
        $self->{upstreamExtensions} = _parseExtensions("$resp");
    });
    return $self;
}

# Whether the upstream announced DSN. Undefined until its EHLO reply is in.
sub upstreamSupportsDsn ($self) {
    return $self->{upstreamExtensions} && $self->{upstreamExtensions}{DSN} ? 1 : 0;
}

sub _parseExtensions ($raw) {
    my %extensions;
    for my $line (split /\r?\n/, $raw) {
        next unless $line =~ /^\d{3}[- ](\S+)/;
        $extensions{uc $1} = 1;
    }
    return \%extensions;
}

# MAIL FROM
sub _cmd_from {
    my ($self, $arg) = @_;
    weaken $self;
    my ($address, $parameters) = _splitAddress($arg);

    return (
        sub {
            my $delay = shift;
            $self->_write_cmd('MAIL FROM:<' . $address . '>' .
                $self->_dsnSuffix($parameters, \%MAIL_DSN_KEYWORDS),
                Mojo::SMTP::Client::CMD_FROM);
            $self->_read_response($delay->begin);
            $self->{expected_code} = Mojo::SMTP::Client::CMD_OK;
        },
        $self->{resp_checker}
    );
}

# RCPT TO
sub _cmd_to {
    my ($self, $arg) = @_;
    weaken $self;

    my @steps;
    for my $recipient (ref $arg eq 'ARRAY' ? @$arg : $arg) {
        my ($address, $parameters) = _splitAddress($recipient);
        push @steps, sub {
            my $delay = shift;
            $self->_write_cmd('RCPT TO:<' . $address . '>' .
                $self->_dsnSuffix($parameters, \%RCPT_DSN_KEYWORDS),
                Mojo::SMTP::Client::CMD_TO);
            $self->_read_response($delay->begin);
            $self->{expected_code} = Mojo::SMTP::Client::CMD_OK;
        },
        $self->{resp_checker};
    }

    return @steps;
}

sub _splitAddress ($arg) {
    return ref $arg eq 'HASH'
        ? ($arg->{address}, $arg->{parameters})
        : ($arg, undef);
}

# Called from inside a command step, so the upstream EHLO reply has arrived by
# the time this runs.
sub _dsnSuffix ($self, $parameters, $allowed) {
    my @wanted = grep { $allowed->{uc $_->{keyword}} } @{$parameters // []};
    return '' unless @wanted;

    # RFC 3461 section 6.1 would have a relay issue the notification itself
    # when the next hop cannot. We cannot generate DSNs, so the parameters are
    # dropped rather than risking the delivery on an upstream that would
    # reject them.
    unless ($self->upstreamSupportsDsn) {
        $self->log->warn('Upstream does not announce DSN; dropping ' .
            join(', ', map { uc $_->{keyword} } @wanted)) if $self->log;
        return '';
    }

    return join '', map {
        ' ' . $_->{keyword} . (defined $_->{value} ? '=' . $_->{value} : '')
    } @wanted;
}

1;

__END__

=head1 NAME

SMTPProxy::RelayClient - Mojo::SMTP::Client that can relay ESMTP parameters

=head1 DESCRIPTION

A subclass of C<Mojo::SMTP::Client> which accepts C<from> and C<to> addresses
as hashrefs carrying ESMTP parameters, so that the RFC 3461 delivery status
notification parameters (C<RET>, C<ENVID>, C<NOTIFY>, C<ORCPT>) requested by
the submitting client can be passed on to the upstream server.

The parameters are only sent to an upstream that announced the C<DSN>
extension in its EHLO response; otherwise they are dropped and a warning is
logged.

=head1 COPYRIGHT

Copyright (c) 2018 by OETIKER+PARTNER AG. All rights reserved.

=cut
