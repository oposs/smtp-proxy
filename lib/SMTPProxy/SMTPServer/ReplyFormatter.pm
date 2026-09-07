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
    # \A and \z rather than ^ and $: Perl's $ matches before a final newline,
    # so "250\n" passed this guard and put a bare LF in a reply line, which is
    # the one thing the rest of this module exists to make impossible. The code
    # is the only part of a reply that is never sanitised, because it is
    # supposed to have been validated here.
    die "Invalid response code '$code'" unless $code =~ /\A[2-5]\d\d\z/;
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
#
# CR and LF are only the two that break framing, though. RFC 5321's textstring
# is a tab plus printable ASCII and nothing else, and the rest of what can
# arrive here is worth excluding on its own account: the same text is written
# to the smtplog, so an ESC in an upstream reply is a terminal escape sequence
# executed in the shell of whoever tails that file. Anything above U+00FF is
# excluded too, because Mojo::IOLoop::Stream::write calls utf8::downgrade and
# dies inside the reactor on a wide character -- and once the text is ASCII the
# 512 limit below is counted in the octets RFC 5321 4.5.3.1.5 actually means,
# rather than in characters, and truncation cannot sever one.
sub _sanitize {
    my $text = shift // '';
    $text =~ s/[^\t\x20-\x7e]+/ /g;
    $text =~ s/\s+$//;
    if (length($text) > MAX_TEXT) {
        $text = substr($text, 0, MAX_TEXT - 3) . '...';
    }
    return $text;
}

1;
