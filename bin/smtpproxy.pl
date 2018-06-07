#!/usr/bin/env perl

use lib qw(); # PERL5LIB
use FindBin; use lib "$FindBin::RealBin/../lib"; use lib "$FindBin::RealBin/../thirdparty/lib/perl5"; # LIBDIR

use Getopt::Long 2.25 qw(:config posix_default no_ignore_case);
use Mojo::Base -strict;
use Pod::Usage 1.14;
use SMTPProxy;
use SMTPProxy::API;

sub main {
    my $opt = {};
    my @mandatory = qw(tohost=s toport=i listenhost=s listenport=i tls_cert=s tls_key=s api=s);
    GetOptions($opt, 'user=s', 'logpath=s','loglevel=s', 'help|h', 'man', @mandatory)
        or pod2usage(1);
    if ($opt->{help}) {
        pod2usage(1);
    }
    if ($opt->{man}) {
        pod2usage(-exitstatus => 0, -verbose => 2);
    }
    for (map { /^(\w+)/; $1 } @mandatory) {
        pod2usage() unless $opt->{$_};
    }

    my $log = Mojo::Log->new(
        path => $opt->{logpath} || '/dev/stderr',
        level => $opt->{loglevel} || 'debug',
    );
    my $api = SMTPProxy::API->new(log => $log, url => $opt->{api});
    my $proxy = SMTPProxy->new(%$opt, api => $api);
    say "Waiting for connections on ". $proxy->listenhost . ':'. $proxy->listenport;
    say "Will forward mails to " . $proxy->tohost . ":" . $proxy->toport;
    $proxy->setup();
    Mojo::IOLoop->start();
}

main;

__END__

=head1 NAME

smtpproxy.pl - SMTP authentication and header injection proxy

=head1 SYNOPSIS

B<smtpproxy.pl> I<options>

    --man           show man-page and exit
 -h,--help          display this help and exit
    --listenhost=x  on which IP should we listen; use 0.0.0.0 to listen on all
    --listenport=x  on which port should we listen
    --tohost=x      host of the SMTP server to proxy to
    --toport=x      port of the SMTP server to proxy to
    --tls_cert=x    file containing a TLS certificate (for STARTTLS)
    --tls_key=x     file containing a TLS key (for STARTTLS)
    --api=x         URL of the authentication API
    --logpath=x     where should the logfile be written to
    --loglevel=x    debug|info|warn|error|fatal

=head1 DESCRIPTION

Starts an SMTP server on the listen host and port. When a connection is
established, communicates with the client up to the point it has both the
envelope and the mail data headers. It requires STARTTLS be used, and takes
authentication details using the PLAIN mechanism.

It then passes the authentication details, envelope headers, and data headers
to a REST API, which determies if the mail is allowed to be sent and, if so,
what additional headers should be inserted.

Once the mail has been fully received, and if it is allowed to be sent, then
an upstream connection to the target SMTP server is established. The mail is
sent using that SMTP server, with the extra headers inserted. The outcome of
this is then relayed to the client.

=head1 COPYRIGHT

Copyright (c) 2018 by OETIKER+PARTNER AG. All rights reserved.

=head1 AUTHOR

S<Jonathan Worthington E<lt>jonathan@oetiker.chE<gt>>

=cut
