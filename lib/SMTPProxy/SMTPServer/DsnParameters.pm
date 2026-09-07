package SMTPProxy::SMTPServer::DsnParameters;

use Mojo::Base -base, -signatures;
require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(validateDsnParameters);

# RFC 3461 gives each of its four parameters a grammar, and two of them a
# length limit. Announcing DSN is what makes a conforming client send them at
# all, and section 5.1 makes answering 501 to a syntactically invalid one a
# MUST for a server that announces it.
#
# Checking at MAIL and RCPT time is the point of this module. Accepting them
# with 250 and finding out at the upstream means the client transfers an entire
# message body before hearing that its envelope was wrong, and leaves the proxy
# writing whatever it was given onto an upstream command line -- with no bound
# on how much of it there is, since a keyword repeated sixty times used to be
# sixty parameters rather than an error.

# RFC 3461 section 4: xtext is printable ASCII other than '+' and '=', with
# anything else written as '+' followed by two hex digits.
my $XTEXT = qr/\A(?:[\x21-\x2a\x2c-\x3c\x3e-\x7e]|\+[0-9A-Fa-f]{2})*\z/;

my %MAIL_KEYWORDS = (RET => \&_checkRet,    ENVID => \&_checkEnvid);
my %RCPT_KEYWORDS = (NOTIFY => \&_checkNotify, ORCPT => \&_checkOrcpt);

# Returns a message describing the first problem found, or undef if the DSN
# parameters in the list are acceptable. Parameters this module knows nothing
# about are left to whoever does.
sub validateDsnParameters ($parameters, $which) {
    my $known = $which eq 'MAIL' ? \%MAIL_KEYWORDS : \%RCPT_KEYWORDS;
    my %seen;
    for my $parameter (@{$parameters // []}) {
        my $keyword = uc($parameter->{keyword} // '');
        my $check = $known->{$keyword} or next;
        return "$keyword given more than once" if $seen{$keyword}++;
        if (my $error = $check->($parameter->{value})) {
            return $error;
        }
    }
    return undef;
}

sub _checkRet ($value) {
    return 'RET requires a value of FULL or HDRS'
        unless defined $value && $value =~ /\A(?:FULL|HDRS)\z/i;
    return undef;
}

# RFC 3461 section 4.4 caps the envelope id at 100 characters.
sub _checkEnvid ($value) {
    return 'ENVID requires a value' unless defined $value && length $value;
    return 'ENVID is limited to 100 characters' if length($value) > 100;
    return 'ENVID must be xtext' unless $value =~ $XTEXT;
    return undef;
}

# RFC 3461 section 4.1: NEVER on its own, or one or more of SUCCESS, FAILURE
# and DELAY. NEVER together with any of the others is a contradiction, and the
# RFC says so explicitly.
sub _checkNotify ($value) {
    return 'NOTIFY requires a value' unless defined $value && length $value;
    my @requested = split /,/, $value, -1;
    return 'NOTIFY has an empty element' if grep { !length } @requested;
    my %seen;
    for my $item (@requested) {
        my $upper = uc $item;
        return "NOTIFY value '$item' is not recognised"
            unless $upper =~ /\A(?:NEVER|SUCCESS|FAILURE|DELAY)\z/;
        return "NOTIFY lists $upper more than once" if $seen{$upper}++;
    }
    return 'NOTIFY=NEVER cannot be combined with other values'
        if $seen{NEVER} && @requested > 1;
    return undef;
}

# RFC 3461 section 4.2: an address type, a semicolon and an xtext address, in
# at most 500 characters.
sub _checkOrcpt ($value) {
    return 'ORCPT requires a value' unless defined $value && length $value;
    return 'ORCPT is limited to 500 characters' if length($value) > 500;
    my ($type, $address) = split /;/, $value, 2;
    return 'ORCPT must be an address type, a semicolon and an address'
        unless defined $type && $type =~ /\A[A-Za-z0-9][A-Za-z0-9-]*\z/
            && defined $address && length $address;
    return 'ORCPT address must be xtext' unless $address =~ $XTEXT;
    return undef;
}

1;

__END__

=head1 NAME

SMTPProxy::SMTPServer::DsnParameters - RFC 3461 parameter validation

=head1 DESCRIPTION

Validates the RFC 3461 delivery status notification parameters (C<RET> and
C<ENVID> on MAIL, C<NOTIFY> and C<ORCPT> on RCPT) at the point they are
received, so that a malformed one is answered with a 501 as RFC 3461 section
5.1 requires, rather than being relayed to the upstream server unexamined.

=head1 COPYRIGHT

Copyright (c) 2018 by OETIKER+PARTNER AG. All rights reserved.

=cut
