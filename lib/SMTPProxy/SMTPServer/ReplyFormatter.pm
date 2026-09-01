package SMTPProxy::SMTPServer::ReplyFormatter;

use Mojo::Base -base;
require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(formatReply);

# RFC 5321 4.5.3.1.5: a reply line is at most 512 octets, which has to cover
# the three digit code, the separator and the trailing CRLF.
use constant MAX_REPLY_LINE => 512;
use constant MAX_TEXT => MAX_REPLY_LINE - length('250 ') - length("\r\n");

sub formatReply {
    my ($code, @lines) = @_;
    die "Invalid response code '$code'" unless $code =~ /^\d\d\d$/;
    die "Must have at least one response line" unless @lines;
    my @formatted;
    while (@lines) {
        my $line = _sanitize(shift @lines);
        push @formatted, $code . (@lines ? '-' : ' ') . $line;
    }
    return join "\r\n", @formatted, "";
}

# Reply text is not ours: it comes from the upstream server and from the API.
# A bare CR or LF in it would break the framing of the reply, which leaves the
# client unable to parse anything and hanging until its own timeout, and would
# let text from upstream inject a whole forged reply line.
sub _sanitize {
    my $text = shift // '';
    $text =~ s/[\r\n]+/ /g;
    $text =~ s/\s+$//;
    if (length($text) > MAX_TEXT) {
        $text = substr($text, 0, MAX_TEXT - 3) . '...';
    }
    return $text;
}

1;
