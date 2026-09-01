package RecordingSMTPServer;

# A deliberately dumb upstream SMTP server for tests. It records the literal
# command lines it is sent, so assertions can be made about exactly what the
# proxy put on the wire rather than about how our own parser understood it.
# The advertised ESMTP extension list is configurable so that tests can drive
# an upstream that does, or does not, support DSN.

use Mojo::Base -base, -signatures;
use Mojo::IOLoop;

has extensions => sub { ['DSN'] };
has lines => sub { [] };
has 'port';

sub clear ($self) {
    @{$self->lines} = ();
    return;
}

# The command lines received, minus the DATA payload.
sub commands ($self) {
    return [grep { !/^\./ } @{$self->lines}];
}

sub commandsMatching ($self, $re) {
    return [grep { /$re/ } @{$self->commands}];
}

sub start ($self) {
    Mojo::IOLoop->server({address => '127.0.0.1', port => $self->port} => sub ($loop, $stream, $id) {
        my $buffer = '';
        my $inData = 0;
        $stream->timeout(30);
        $stream->write("220 recording.upstream ESMTP ready\r\n");
        $stream->on(read => sub ($stream, $bytes) {
            $buffer .= $bytes;
            while ($buffer =~ s/^([^\n]*)\n//) {
                my $line = $1;
                $line =~ s/\r$//;
                push @{$self->lines}, $line;
                if ($inData) {
                    next unless $line eq '.';
                    $inData = 0;
                    $stream->write("250 OK message accepted\r\n");
                }
                elsif ($line =~ /^EHLO/i) {
                    my @ext = @{$self->extensions};
                    my $reply = "250-recording.upstream\r\n";
                    $reply .= "250-$_\r\n" for @ext[0 .. $#ext - 1];
                    $reply .= '250 ' . (@ext ? $ext[-1] : 'HELP') . "\r\n";
                    $stream->write($reply);
                }
                elsif ($line =~ /^(HELO|MAIL|RCPT|RSET|NOOP)/i) {
                    $stream->write("250 OK\r\n");
                }
                elsif ($line =~ /^DATA/i) {
                    $inData = 1;
                    $stream->write("354 Go ahead\r\n");
                }
                elsif ($line =~ /^QUIT/i) {
                    $stream->write("221 Bye\r\n");
                    $stream->close_gracefully;
                }
                else {
                    $stream->write("502 Command not implemented\r\n");
                }
            }
        });
    });
    return;
}

1;
