use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../thirdparty/lib/perl5";
use strict;
use warnings;
use v5.16;

use SMTPProxy::SMTPServer::CommandParser;
use Test::More;

# SP-28: RFC 5321 section 4.1.1.2 spells the keywords "MAIL FROM:" and
# "RCPT TO:", but section 2.4 states that verbs and argument values are not
# case sensitive, giving '"TO:" or "to:"' as its example. Any casing of the
# keyword is therefore accepted.
my @cases = (
    {
        desc       => 'uppercase FROM as per RFC 5321',
        arguments  => 'FROM:<sender@foobar.com>',
        from       => 'sender@foobar.com',
        parameters => [],
    },
    {
        desc       => 'capitalized From',
        arguments  => 'From:<sender@foobar.com>',
        from       => 'sender@foobar.com',
        parameters => [],
    },
    {
        desc       => 'capitalized From with space before the address',
        arguments  => 'From: <sender@foobar.com>',
        from       => 'sender@foobar.com',
        parameters => [],
    },
    {
        desc       => 'capitalized From with parameters',
        arguments  => 'From:<sender@foobar.com> SIZE=1234',
        from       => 'sender@foobar.com',
        parameters => [{ keyword => 'SIZE', value => '1234' }],
    },
    {
        desc       => 'lowercase from',
        arguments  => 'from:<sender@foobar.com>',
        from       => 'sender@foobar.com',
        parameters => [],
    },
    {
        desc       => 'mIxEd case FrOm',
        arguments  => 'FrOm:<sender@foobar.com>',
        from       => 'sender@foobar.com',
        parameters => [],
    },
    {
        desc  => 'missing address is rejected',
        arguments => 'From:',
        error => 'invalid MAIL arguments',
    },
    {
        desc  => 'a different keyword is still rejected',
        arguments => 'SENDER:<sender@foobar.com>',
        error => 'invalid MAIL arguments',
    },
);

# The same rule applies to RCPT TO:. Only the reply code is asserted for the
# rejection case, so this does not depend on the wording of the error.
my @rcptCases = (
    {
        desc => 'uppercase TO as per RFC 5321',
        arguments => 'TO:<rcpt@foobaz.com>',
        to => 'rcpt@foobaz.com',
        parameters => [],
    },
    {
        desc => 'capitalized To',
        arguments => 'To:<rcpt@foobaz.com>',
        to => 'rcpt@foobaz.com',
        parameters => [],
    },
    {
        desc => 'lowercase to, the example given in RFC 5321 section 2.4',
        arguments => 'to:<rcpt@foobaz.com>',
        to => 'rcpt@foobaz.com',
        parameters => [],
    },
    {
        desc => 'mIxEd case tO with parameters',
        arguments => 'tO:<rcpt@foobaz.com> NOTIFY=NEVER',
        to => 'rcpt@foobaz.com',
        parameters => [{ keyword => 'NOTIFY', value => 'NEVER' }],
    },
    {
        desc => 'a different keyword is still rejected',
        arguments => 'FOR:<rcpt@foobaz.com>',
        rejected => 1,
    },
);

for my $case (@cases) {
    subtest "MAIL $case->{desc}" => sub {
        my ($parsed, $buffer) = parseCommand("MAIL $case->{arguments}\r\nRSET\r\n");
        is $parsed->{command}, 'MAIL', 'Parsed the MAIL command';
        like $buffer, qr/^RSET/, 'Parsed command trimmed from the buffer';
        if ($case->{error}) {
            is $parsed->{error}, $case->{error}, 'Correct error reported';
            is $parsed->{suggested_reply}, 501, 'Suggested reply is 501';
            is $parsed->{from}, undef, 'No sender extracted';
        }
        else {
            is $parsed->{error}, undef, 'No error reported';
            is $parsed->{from}, $case->{from}, 'Correct sender extracted';
            is_deeply $parsed->{parameters}, $case->{parameters},
                'Correct parameters extracted';
        }
    };
}

for my $case (@rcptCases) {
    subtest "RCPT $case->{desc}" => sub {
        my ($parsed, $buffer) = parseCommand("RCPT $case->{arguments}\r\nRSET\r\n");
        is $parsed->{command}, 'RCPT', 'Parsed the RCPT command';
        like $buffer, qr/^RSET/, 'Parsed command trimmed from the buffer';
        if ($case->{rejected}) {
            is $parsed->{suggested_reply}, 501, 'Suggested reply is 501';
            is $parsed->{to}, undef, 'No recipient extracted';
        }
        else {
            is $parsed->{error}, undef, 'No error reported';
            is $parsed->{to}, $case->{to}, 'Correct recipient extracted';
            is_deeply $parsed->{parameters}, $case->{parameters},
                'Correct parameters extracted';
        }
    };
}

# ---------------------------------------------------------------------------
# ESMTP parameters, the null return path, and malformed input.
# ---------------------------------------------------------------------------

sub parse {
    my ($parsed) = parseCommand(shift() . "\r\n");
    return $parsed;
}

# RFC 3461 DSN parameters must survive parsing.

my $rcpt = parse('RCPT TO:<a@b.com> NOTIFY=SUCCESS,FAILURE ORCPT=rfc822;a@b.com');
is $rcpt->{to}, 'a@b.com', 'RCPT with DSN parameters yields the address';
is_deeply $rcpt->{parameters}, [
        { keyword => 'NOTIFY', value => 'SUCCESS,FAILURE' },
        { keyword => 'ORCPT',  value => 'rfc822;a@b.com'  },
    ], 'RCPT NOTIFY and ORCPT parsed';

my $mail = parse('MAIL FROM:<a@b.com> RET=HDRS ENVID=QQ314159');
is $mail->{from}, 'a@b.com', 'MAIL with DSN parameters yields the address';
is_deeply $mail->{parameters}, [
        { keyword => 'RET',   value => 'HDRS'     },
        { keyword => 'ENVID', value => 'QQ314159' },
    ], 'MAIL RET and ENVID parsed';

# The null return path. DSN messages themselves are sent with MAIL FROM:<>,
# so a proxy that cannot parse it cannot relay a bounce.

my $nullFrom = parse('MAIL FROM:<>');
ok !$nullFrom->{error}, 'MAIL FROM:<> is accepted';
is $nullFrom->{from}, '', 'MAIL FROM:<> yields the empty reverse path';
is_deeply $nullFrom->{parameters}, [], 'MAIL FROM:<> has no parameters';

my $nullFromParams = parse('MAIL FROM:<> RET=FULL');
ok !$nullFromParams->{error}, 'MAIL FROM:<> with parameters is accepted';
is $nullFromParams->{from}, '', 'MAIL FROM:<> with parameters yields empty path';
is_deeply $nullFromParams->{parameters}, [{ keyword => 'RET', value => 'FULL' }],
    'MAIL FROM:<> parameters parsed';

# An empty forward path is not legal on RCPT.

my $nullTo = parse('RCPT TO:<>');
is $nullTo->{error}, 'invalid RCPT arguments', 'RCPT TO:<> is rejected';
is $nullTo->{suggested_reply}, 501, 'RCPT TO:<> suggests a 501 reply';

# RFC 5321 esmtp-param allows a bare keyword with no value.

my $valueless = parse('RCPT TO:<a@b.com> SMTPUTF8');
ok !$valueless->{error}, 'valueless parameter is accepted';
is_deeply $valueless->{parameters}, [{ keyword => 'SMTPUTF8', value => undef }],
    'valueless parameter is recorded with an undefined value';

# Malformed parameters must be rejected rather than silently dropped, or the
# client believes the proxy honoured something it discarded.

for my $bad ('NOTIFY=', '=SUCCESS', 'NOTIFY=A=B', '-BAD=1') {
    my $parsed = parse("RCPT TO:<a\@b.com> $bad");
    is $parsed->{suggested_reply}, 501, "malformed parameter '$bad' is rejected";
}

# ---------------------------------------------------------------------------
# RFC 5321 4.5.1 minimum implementation: EHLO, HELO, MAIL, RCPT, DATA, RSET,
# NOOP, QUIT and VRFY must all be understood.
# ---------------------------------------------------------------------------

my $helo = parse('HELO client.example.com');
is $helo->{command}, 'HELO', 'HELO is recognised';
ok !$helo->{error}, 'HELO is not rejected as an unknown command';
is $helo->{domain}, 'client.example.com', 'HELO domain is captured';

my $ehlo = parse('EHLO client.example.com');
is $ehlo->{domain}, 'client.example.com', 'EHLO domain is captured';

my $noop = parse('NOOP');
is $noop->{command}, 'NOOP', 'NOOP is recognised';
ok !$noop->{error}, 'NOOP is not rejected as an unknown command';

# RFC 5321 4.1.1.9 allows NOOP an optional argument, which is ignored.
my $noopArg = parse('NOOP keep alive');
ok !$noopArg->{error}, 'NOOP with an argument is accepted';

# ---------------------------------------------------------------------------
# The unparsed remainder of the buffer must survive intact, or any client that
# puts two commands in one packet loses everything after the first.
# ---------------------------------------------------------------------------

my ($first, $rest) = parseCommand("MAIL FROM:<a\@b.com>\r\nRCPT TO:<c\@d.com>\r\nDATA\r\n");
is $first->{command}, 'MAIL', 'First of several pipelined commands parsed';
is $rest, "RCPT TO:<c\@d.com>\r\nDATA\r\n",
    'Remaining commands left in the buffer untouched';

my ($second, $stillRest) = parseCommand($rest);
is $second->{command}, 'RCPT', 'Second pipelined command parses from the remainder';
is $stillRest, "DATA\r\n", 'Third command still queued';

my ($third) = parseCommand($stillRest);
is $third->{command}, 'DATA', 'Third pipelined command parses';

# ---------------------------------------------------------------------------
# RFC 4954 2: the AUTH mechanism name is case insensitive.
# ---------------------------------------------------------------------------

is parse('AUTH PLAIN dGVzdA==')->{mechanism}, 'PLAIN', 'Uppercase mechanism';
is parse('AUTH plain dGVzdA==')->{mechanism}, 'PLAIN', 'Lowercase mechanism normalised';
is parse('AUTH PlAiN dGVzdA==')->{mechanism}, 'PLAIN', 'Mixed case mechanism normalised';
is parse('AUTH login')->{mechanism}, 'LOGIN', 'LOGIN mechanism normalised';
is parse('AUTH plain dGVzdA==')->{initial}, 'dGVzdA==', 'Initial response preserved';

# A bare AUTH is a syntax error, and must not warn on the way to saying so.
my @warnings;
my $bareAuth = do {
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    parse('AUTH');
};
is $bareAuth->{suggested_reply}, 501, 'Bare AUTH is rejected';
is_deeply \@warnings, [], 'Bare AUTH does not warn about undefined values';

# PING is not an SMTP command and nothing ever handled it: the parser accepted
# it and the connection then answered 503 from whichever state it was in. It is
# treated like any other command we do not implement.

my $ping = parse('PING');
is $ping->{suggested_reply}, 502, 'PING is not implemented';
is $ping->{error}, 'unknown command', 'PING reported as an unknown command';
is parse('PING hello')->{suggested_reply}, 502, 'PING with an argument likewise';

# ---------------------------------------------------------------------------
# A line we reject must still be consumed. Returning it unchanged left the
# caller holding a buffer whose head could never parse: the client drew a 500
# for that line and another for every packet it sent afterwards, the buffer
# grew without bound, and no later command was ever reached.
# ---------------------------------------------------------------------------

for my $case (
    ['a line with an embedded CR', "MAIL FROM:<a\rb>\r\n"],
    ['a bare empty line',          "\r\n"],
    ['a bare LF terminator',       "NOOP\n"],
    ['a line not starting a verb', " NOOP\r\n"],
) {
    my ($desc, $bad) = @$case;
    my ($rejected, $remainder) = parseCommand($bad . "RSET\r\n");
    is $rejected->{suggested_reply}, 500, "500 for $desc";
    is $remainder, "RSET\r\n", "$desc is consumed, not left to re-parse";
}

# The whole buffer drains: the rejection costs one 500, not one per read.
my $wedge = "MAIL FROM:<a\rb>\r\nNOOP\r\nRSET\r\n";
my @drained;
while (1) {
    my ($command, $rest) = parseCommand($wedge);
    last unless $command;
    push @drained, $command->{error} // $command->{command};
    $wedge = $rest;
    last if @drained > 4;
}
is_deeply \@drained, ['malformed command', 'NOOP', 'RSET'],
    'Commands after a rejected line are still reached';
is $wedge, '', 'Buffer fully drained';

# An incomplete line has no terminator to consume, so it must be held intact
# until the rest of it arrives.
my ($partial, $held) = parseCommand('MAIL FRO');
is $partial, undef, 'An incomplete line is not a command';
is $held, 'MAIL FRO', 'An incomplete line is held, not discarded';

# ---------------------------------------------------------------------------
# A command with no argument at all reaches the argument matches as undef. The
# AUTH branch guards for that; MAIL and RCPT did not, so every bare MAIL or
# RCPT -- which is what a probe or a broken client sends -- matched undef and
# warned. The reply was already right; the noise was not.
# ---------------------------------------------------------------------------

my @warnings;
my ($bareMail, $bareRcpt);
{
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    $bareMail = parse('MAIL');
    $bareRcpt = parse('RCPT');
}
is $bareMail->{suggested_reply}, 501, 'Bare MAIL is still rejected with 501';
is $bareRcpt->{suggested_reply}, 501, 'Bare RCPT is still rejected with 501';
is_deeply \@warnings, [], 'Bare MAIL and RCPT parse without warning';

# A parameter list is captured by an optional group, and the test that decided
# whether to parse it was a truthiness test. "0" is a well formed esmtp-keyword
# under the grammar below, so it was the one parameter list that evaluated
# false and vanished -- exactly the silent drop the comment in _parseParameters
# says must not happen.

my $zeroMail = parse('MAIL FROM:<a@b.com> 0');
is_deeply $zeroMail->{parameters}, [{ keyword => '0', value => undef }],
    'A MAIL parameter list of "0" is not dropped';
my $zeroRcpt = parse('RCPT TO:<a@b.com> 0');
is_deeply $zeroRcpt->{parameters}, [{ keyword => '0', value => undef }],
    'A RCPT parameter list of "0" is not dropped';

# RFC 4954 section 4 spells a SASL mechanism name as up to 20 characters of
# upper alpha, digit, hyphen and underscore. \w excludes the hyphen, so every
# hyphenated mechanism -- CRAM-MD5, SCRAM-SHA-256, the two a client is most
# likely to try before falling back -- failed to parse and drew 501. A client
# reads 501 as "that line was malformed", not as "pick another mechanism", so
# it has no reason to fall back; 504 is the answer that says what it needs.

my $cramMd5 = parse('AUTH CRAM-MD5');
ok !$cramMd5->{error}, 'A hyphenated AUTH mechanism parses';
is $cramMd5->{mechanism}, 'CRAM-MD5', 'The hyphenated mechanism name is kept';

my $scram = parse('AUTH SCRAM-SHA-256 abcd');
is $scram->{mechanism}, 'SCRAM-SHA-256', 'Hyphens throughout the name are kept';
is $scram->{initial}, 'abcd', 'The initial response is still separated off';

my $underscore = parse('AUTH X_MECH');
is $underscore->{mechanism}, 'X_MECH', 'An underscore is a legal mech-char too';

# The bound is part of the grammar, so a name that cannot be one is still a
# malformed argument rather than an unsupported mechanism.
my $tooLong = parse('AUTH ' . ('A' x 21));
is $tooLong->{suggested_reply}, 501, 'An over-long mechanism name is rejected';

# RFC 5321 4.1.1.1 and 4.1.1.6 make the argument mandatory: an EHLO or HELO
# carries a domain, a VRFY carries a string. The commands that take no argument
# already validate that none was given, so accepting these with 250 and an
# undefined domain was an asymmetry with nothing behind it -- and the domain
# goes on to be the identity the session is logged under.

for my $bare ('EHLO', 'HELO', 'VRFY') {
    my $parsed = parse($bare);
    is $parsed->{suggested_reply}, 501, "Bare $bare is rejected";
    like $parsed->{error}, qr/required/, "Bare $bare says what is missing";
}

my $ehloStillWorks = parse('EHLO client.example.com');
ok !$ehloStillWorks->{error}, 'EHLO with a domain is still accepted';
is $ehloStillWorks->{domain}, 'client.example.com', 'and still carries it';

my $vrfyStillWorks = parse('VRFY someone@example.com');
ok !$vrfyStillWorks->{error}, 'VRFY with a string is still accepted';
is $vrfyStillWorks->{string}, 'someone@example.com', 'and still carries it';

# RFC 5321 4.1.2 builds an esmtp-value out of characters excluding "=", space
# and the control characters -- which is to say printable ASCII. The class used
# here also admitted DEL and every octet from 0x80 up, so a parameter value
# could put bytes on an upstream command line in a session where SMTPUTF8 was
# never negotiated.

for my $bad ("X=caf\xe9", "X=del\x7f", "X=\xff") {
    my $parsed = parse("RCPT TO:<a\@b.com> $bad");
    is $parsed->{suggested_reply}, 501,
        'a parameter value outside printable ASCII is rejected';
}

my $printable = parse('RCPT TO:<a@b.com> X=~!$%^&*()_+{}|:"<>?');
ok !$printable->{error}, 'printable ASCII is still accepted in a value';

done_testing();
