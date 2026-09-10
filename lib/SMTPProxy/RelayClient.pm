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

# This subclass reaches past the documented interface of its superclass: it
# overrides the private _cmd_from and _cmd_to, calls the private _write_cmd and
# _read_response, and reads the private {resp_checker} and {expected_code}
# fields out of the instance hash. None of that appears in the POD, so none of
# it is promised. The cpanfile therefore pins the version exactly, and the
# check below turns the half of the drift that is detectable into a failure at
# load time rather than a failure in a promise callback while relaying a
# message somebody sent.
for my $method (qw(_cmd_from _cmd_to _write_cmd _read_response)) {
    Mojo::SMTP::Client->can($method) or die __PACKAGE__ .
        " requires the private Mojo::SMTP::Client::$method, which the " .
        "installed version does not provide\n";
}

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
    my ($address, $parameters) = ref $arg eq 'HASH'
        ? ($arg->{address}, $arg->{parameters})
        : ($arg, undef);
    _assertRelayable($address);
    return ($address, $parameters);
}

# Every address the proxy relays reaches an upstream command line through here,
# and the superclass writes that line followed by CRLF without looking at it.
# The command parser is the proxy's single point of validation for what a
# client sent, but it is not on the path for an address the API substituted for
# the envelope sender: that arrives as a JSON string and is interpolated
# straight into MAIL FROM:<...>. A CR or LF in one is a further command
# injected into an authenticated upstream session, which is the same class of
# bug as the reply-line injection guarded against on the client-facing side.
#
# RFC 5321 4.1.2 builds a path out of printable ASCII; the angle brackets are
# excluded on top of that because this code supplies them. An empty address is
# the null return path and is allowed.
sub _assertRelayable ($address) {
    $address //= '';
    return if $address =~ /\A[\x21-\x7e]*\z/ && $address !~ /[<>]/;
    die "Refusing to relay the address '$address': it contains characters " .
        "that cannot appear in an SMTP command line\n";
}

# Called from inside a command step, so the upstream EHLO reply has arrived by
# the time this runs.
sub _dsnSuffix ($self, $parameters, $allowed) {
    my @wanted = grep { $allowed->{uc $_->{keyword}} } @{$parameters // []};
    return '' unless @wanted;

    # RFC 3461 section 5.2.2 is the one that governs this: a relay whose next
    # hop does not support DSN is required to issue the notification itself.
    # (Section 6.1 governs the envelope of a DSN message, which is a different
    # thing entirely.) We cannot generate DSNs, so the parameters are dropped
    # rather than risking the delivery on an upstream that would reject them.
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

=head1 CAVEATS

C<Mojo::SMTP::Client> offers no supported way to append ESMTP parameters to a
MAIL FROM or RCPT TO command, so this subclass overrides its private
C<_cmd_from> and C<_cmd_to>, calls its private C<_write_cmd> and
C<_read_response>, and reads its private C<resp_checker> and C<expected_code>
instance fields. None of these are part of its documented interface. The
version is pinned exactly in the F<cpanfile> for that reason, and this module
refuses to load if the private methods it needs have gone away.

=head1 COPYRIGHT

Copyright (c) 2018 by OETIKER+PARTNER AG. All rights reserved.

=cut
