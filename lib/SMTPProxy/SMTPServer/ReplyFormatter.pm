package SMTPProxy::SMTPServer::ReplyFormatter;

use Mojo::Base -base;
require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(formatReply);

sub formatReply {
    my ($code, @lines) = @_;
    die "Invalid response code '$code'" unless $code =~ /^\d\d\d$/;
    die "Must have at least one response line" unless @lines;
    my @formatted;
    while (@lines) {
        my $line = shift @lines;
        push @formatted, $code . (@lines ? '-' : ' ') . $line;
    }
    return join "\r\n", @formatted, "";
}

1;
