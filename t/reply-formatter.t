use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../thirdparty/lib/perl5";
use strict;
use warnings;
use v5.16;

use SMTPProxy::SMTPServer::ReplyFormatter;
use Test::More;

plan tests => 19;

# The ordinary cases must keep working.

is formatReply(250, 'OK'), "250 OK\r\n", 'Single line reply';
is formatReply(250, 'greeting', 'STARTTLS', 'DSN'),
    "250-greeting\r\n250-STARTTLS\r\n250 DSN\r\n", 'Multi line reply';

# Text reaching the formatter comes from the upstream server and from the API,
# and an SMTP reply line may not contain a bare CR or LF (RFC 5321 4.5.3.1.5).
# A reply that does is unparseable, and the client hangs until it times out.

my $embeddedLf = formatReply(550, "Requested action not taken: nope\n");
is $embeddedLf, "550 Requested action not taken: nope\r\n",
    'Trailing newline in the message does not break the reply';
unlike substr($embeddedLf, 0, length($embeddedLf) - 2), qr/[\r\n]/,
    'No stray CR or LF inside the reply line';

my $embeddedCrLf = formatReply(550, "first\r\nsecond");
is $embeddedCrLf, "550 first second\r\n",
    'Embedded CRLF is folded into the single reply line';

# An upstream error text is attacker-influenced in the general case, so it must
# not be able to inject an extra reply line the client would act on.
my $injection = formatReply(550, "rejected\r\n250 OK, go ahead");
is $injection, "550 rejected 250 OK, go ahead\r\n",
    'Cannot inject a forged reply line';
is scalar(() = $injection =~ /\r\n/g), 1, 'Injection attempt yields one line';

my $cr = formatReply(550, "carriage\rreturn");
is $cr, "550 carriage return\r\n", 'Bare CR is folded too';

# Same protection on every line of a multiline reply.
my $multi = formatReply(250, "one\r\ntwo", 'three');
is $multi, "250-one two\r\n250 three\r\n", 'Continuation lines are sanitised';

# RFC 5321 4.5.3.1.5: 512 octets per reply line including code and CRLF.
my $long = formatReply(550, 'x' x 1000);
ok length($long) <= 512, 'Over-long reply line is truncated to 512 octets';
like $long, qr/^550 x+\.\.\.\r\n$/, 'Truncated reply is still well formed';

# Guard rails that already existed must survive.
eval { formatReply(9999, 'nope') };
like $@, qr/Invalid response code/, 'Bad response code still dies';

# CR and LF are not the only bytes that must not reach the wire. The same text
# is written to the smtplog, which an operator reads with tail, so an ESC from
# an upstream reply is a terminal escape sequence executed in their shell. RFC
# 5321's textstring is tab plus printable ASCII and nothing else.

my $controls = formatReply(550, "esc\x1b[31mred\x00nul\x07bell");
unlike substr($controls, 0, length($controls) - 2), qr/[^\t\x20-\x7e]/,
    'Every control character is folded out of the reply text';
is $controls, "550 esc [31mred nul bell\r\n",
    'Folding a control leaves the surrounding text intact';

# Mojo::IOLoop::Stream::write calls utf8::downgrade, which dies inside the
# reactor on any code point above U+00FF -- and upstream error text is exactly
# where one arrives. The 512 limit is octets, not characters, for the same
# reason.

my $wide = formatReply(550, "caf\x{e9} \x{263a} smile");
ok !utf8::is_utf8($wide) || utf8::downgrade(my $copy = $wide, 1),
    'A reply with wide input can still be written as bytes';
unlike substr($wide, 0, length($wide) - 2), qr/[^\t\x20-\x7e]/,
    'Wide characters do not survive into the reply';

my $longWide = formatReply(550, "\x{263a}" x 1000);
ok length($longWide) <= 512, 'An over-long wide reply is capped in octets';

# Perl's $ matches before a final newline, so the code guard let a trailing one
# through and emitted the bare LF the whole module exists to prevent. The
# argument is the one part of a reply that is never sanitised, on the grounds
# that it was already validated.

eval { formatReply("250\n", 'OK') };
like $@, qr/Invalid response code/, 'A response code with a newline is rejected';

eval { formatReply(100, 'nope') };
like $@, qr/Invalid response code/, 'A code outside the 2xx-5xx range is rejected';
