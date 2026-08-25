use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../thirdparty/lib/perl5";
use strict;
use warnings;
use v5.16;

use SMTPProxy::SMTPServer::CommandParser;
use Test::More;

# SP-28: RFC 5321 section 4.1.1.2 spells the keyword "MAIL FROM:", but some clients
# send "MAIL From:"; both are accepted, anything else is still rejected.
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
        desc  => 'lowercase from is rejected',
        arguments => 'from:<sender@foobar.com>',
        error => 'invalid MAIL arguments',
    },
    {
        desc  => 'mIxEd case FrOm is rejected',
        arguments => 'FrOm:<sender@foobar.com>',
        error => 'invalid MAIL arguments',
    },
    {
        desc  => 'missing address is rejected',
        arguments => 'From:',
        error => 'invalid MAIL arguments',
    },
);

plan tests => scalar(@cases);

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
