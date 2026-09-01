package SMTPProxy::SMTPServer::CommandParser;

use Mojo::Base -base;
require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(parseCommand);

sub parseCommand {
    my $buffer = shift;
    my $parsed;
    if ($buffer =~ /^([A-Za-z]+)(?: (.*))?\r\n(.*)/) {
        # Trim parsed command from the buffer, set up parsed result.
        $buffer = $3;
        my $command = uc $1;
        my $arguments = $2;
        $parsed = { command => $command };

        # Now parse by command.
        if ($command eq 'EHLO' || $command eq 'EHLO') {
            $parsed->{domain} = $arguments;
        }
        elsif ($command eq 'PING') {
            $parsed->{text} = $arguments;
        }
        elsif ($command eq 'QUIT' || $command eq 'STARTTLS' || $command eq 'DATA' ||
               $command eq 'RSET') {
            if ($arguments) {
                $parsed->{error} = 'no arguments allowed';
                $parsed->{suggested_reply} = 501;
            }
        }
        elsif ($command eq 'AUTH') {
            if ($arguments =~ /^(\w+)(?: (.*))?$/) {
                $parsed->{mechanism} = $1;
                $parsed->{initial} = $2;
            }
            else {
                $parsed->{error} = 'invalid AUTH arguments';
                $parsed->{suggested_reply} = 501;
            }
        }
        elsif ($command eq 'MAIL') {
            # SP-28: RFC 5321 section 2.4 says verbs and argument values are
            # not case sensitive, offering '"TO:" or "to:"' as its example, so
            # the keyword is matched without regard to case.
            # An empty reverse path (MAIL FROM:<>) is the null return path
            # used by bounces and DSN messages, so it must be accepted.
            if ($arguments =~ /^FROM:\s*<([^>]*)>(?: (.*))?$/i) {
                $parsed->{from} = $1;
                if ($2) {
                    my $parameters = _parseParameters($2);
                    if ($parameters) {
                        $parsed->{parameters} = $parameters;
                    }
                    else {
                        $parsed->{error} = 'invalid MAIL parameters';
                        $parsed->{suggested_reply} = 501;
                    }
                }
                else {
                    $parsed->{parameters} = [];
                }
            }
            else {
                $parsed->{error} = 'invalid MAIL arguments';
                $parsed->{suggested_reply} = 501;
            }
        }
        elsif ($command eq 'RCPT') {
            if ($arguments =~ /^TO:\s*<([^>]+)>(?: (.*))?$/i) {
                $parsed->{to} = $1;
                if ($2) {
                    my $parameters = _parseParameters($2);
                    if ($parameters) {
                        $parsed->{parameters} = $parameters;
                    }
                    else {
                        $parsed->{error} = 'invalid RCPT parameters';
                        $parsed->{suggested_reply} = 501;
                    }
                }
                else {
                    $parsed->{parameters} = [];
                }
            }
            else {
                $parsed->{error} = 'invalid RCPT arguments';
                $parsed->{suggested_reply} = 501;
            }
        }
        elsif ($command eq 'VRFY') {
            $parsed->{string} = $arguments;
        }
        else {
            $parsed->{error} = 'unknown command';
            $parsed->{suggested_reply} = 502;
        }
    }
    elsif ($buffer =~ /\n/) {
        $parsed = { error => 'malformed command', suggested_reply => 500 };
    }
    return ($parsed, $buffer);
}

# Parses an esmtp-param list (RFC 5321 section 4.1.2). Returns an arrayref of
# keyword/value pairs, or undef if any parameter is malformed. The value is
# undef for a bare keyword, which the grammar permits. Returning undef rather
# than skipping a bad parameter matters: silently dropping one would tell the
# client we honoured something we discarded.
sub _parseParameters {
    my @paramStrings = split ' ', shift;
    my @parameters;
    for (@paramStrings) {
        if (/^([A-Za-z0-9][A-Za-z0-9-]*)(?:=([^\x00-\x20=]+))?$/) {
            push @parameters, { keyword => $1, value => $2 };
        }
        else {
            return undef;
        }
    }
    return \@parameters;
}

1;
