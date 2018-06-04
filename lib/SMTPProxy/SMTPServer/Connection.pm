package SMTPProxy::SMTPServer::Connection;

use Mojo::Base -base;
use Mojo::IOLoop;
use Mojo::IOLoop::TLS;
use SMTPProxy::SMTPServer::CommandParser;
use SMTPProxy::SMTPServer::ReplyFormatter;

has [qw(loop stream id server clientAddress auth_plain mail to data vrfy rset quit)];

# States we may be in.
use constant {
    WANT_INITIAL_EHLO   => 0,
    WANT_STARTTLS       => 1,
    WANT_TLS_EHLO       => 2,
    WANT_AUTH           => 3,
    WANT_MAIL           => 4,
    WANT_RCPT           => 5,
    WANT_DATA           => 6,
};

sub log {
    shift->server->log
}

sub process {
    my $self = shift;
    $self->stream->write(formatReply(220, $self->server->service_name . ' SMTP service ready'));
    $self->{state} = WANT_INITIAL_EHLO;
    $self->stream->on(read => sub {
        # Append bytes to input buffer.
        my ($stream, $bytes) = @_;
        state $buffer;
        $buffer .= $bytes;

        # Try to parse a command.
        my $command;
        ($command, $buffer) = parseCommand($buffer);
        if ($command) {
            if ($command->{error}) {
                $self->stream->write(formatReply(
                    $command->{suggested_reply} // 500,
                    $command->{error}
                ));
            }
            else {
                $self->_processCommand($command);
            }
        }

            });
}

my @STATE_METHODS = (
    '_processInitialEhlo',
    '_processStartTLS',
    '_processTLSEhlo',
    '_processAuth',
    '_processMail',
    '_processRcpt',
    '_processData',
);

sub _processCommand {
    my ($self, $command) = @_;
    my $commandName = $command->{command};

    # QUIT and NOOP are valid in any state.
    if ($commandName eq 'QUIT') {
        $self->stream->write(
            formatReply(221, $self->server->service_name . 'Service closing transmission channel'),
            sub { Mojo::IOLoop->remove($self->id) });
    }
    elsif ($commandName eq 'NOOP') {
        $self->stream->write(formatReply(250, 'OK'));
    }
    else {
        # Go by state.
        my $methodName = @STATE_METHODS[$self->{state}];
        $self->$methodName($command);
    }
}

sub _processInitialEhlo {
    my ($self, $command) = @_;
    my $commandName = $command->{command};
    if ($commandName eq 'EHLO' || $commandName eq 'HELO') {
        $self->stream->write(formatReply(250,
            $self->server->service_name . ' offers a warm hug of welcome',
            'STARTTLS'));
        $self->{state} = WANT_STARTTLS;
    }
    else {
        $self->stream->write(formatReply(503, 'Bad sequence of commands'));
    }
}

sub _processStartTLS {
    my ($self, $command) = @_;
    my $commandName = $command->{command};
    if ($commandName eq 'STARTTLS') {
        $self->stream->write(formatReply(220, 'Go ahead'), sub {
            my $tls = Mojo::IOLoop::TLS->new($self->stream->steal_handle);
            $tls->on(upgrade => sub {
                my ($tls, $new_handle) = @_;
                $self->log->debug("Successful TLS upgrade for " . $self->clientAddress);
                say "upgraded";
            });
            $tls->on(error => sub {
                my ($tls, $err) = @_;
                $self->log->info("Failed TLS upgrade for " . $self->clientAddress . ": $err");
                Mojo::IOLoop->remove($self->id);
            });
            $tls->negotiate(
                server => 1,
                tls_cert => $self->server->tls_cert,
                tls_key => $self->server->tls_key
            );
            $self->log->debug("Starting TLS upgrade for " . $self->clientAddress);
        });
    }
    else {
        $self->stream->write(formatReply(554, 'Command refused due to lack of security'));
    }
}

1;

__END__

=head1 NAME

SMTPProxy::SMTPServer::Connection - connection object for SMTPProxy::SMTPServer

=head1 DESCRIPTION

Connection object for C<SMTPProxy::SMTPServer>; see its documentation for
further details.

=head1 COPYRIGHT

Copyright (c) 2018 by OETIKER+PARTNER AG. All rights reserved.

=head1 AUTHOR

S<Jonathan Worthington E<lt>jonathan@oetiker.chE<gt>>

=cut
