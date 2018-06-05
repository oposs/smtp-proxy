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
        elsif ($command eq 'QUIT' || $command eq 'STARTTLS') {
            if ($arguments) {
                $parsed->{error} = 'no arguments allowed';
                $parsed->{suggested_reply} = 501;
            }
        }
        elsif ($command eq 'AUTH') {
            if ($arguments =~ /^(\w+)(?: (.*))$/) {
                $parsed->{mechanism} = $1;
                $parsed->{initial} = $2;
            }
            else {
                $parsed->{error} = 'invalid AUTH arguments';
                $parsed->{suggested_reply} = 501;
            }
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

1;
