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

done_testing();
