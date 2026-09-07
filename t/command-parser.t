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

plan tests => scalar(@cases) + scalar(@rcptCases);

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
