package SMTPProxy::SMTPServer::Connection;

use Mojo::Base -base;
use Mojo::IOLoop;
use Mojo::IOLoop::Stream;
use Mojo::IOLoop::TLS;
use MIME::Base64;
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
    $self->_startReader();
}

sub _startReader {
    my $self = shift;
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
                $self->stream(Mojo::IOLoop::Stream->new($new_handle));
                $self->{state} = WANT_TLS_EHLO;
                $self->_startReader();
                $self->stream->start;
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
        $self->stream->write(formatReply(530, 'Must issue a STARTTLS command first'));
    }
}

sub _processTLSEhlo {
    my ($self, $command) = @_;
    my $commandName = $command->{command};
    if ($commandName eq 'EHLO' || $commandName eq 'HELO') {
        $self->stream->write(formatReply(250,
            $self->server->service_name . ' offers another warm hug of welcome',
            'AUTH PLAIN'));
        $self->{state} = WANT_AUTH;
    }
    else {
        # RFC 3207 says that the client SHOULD sent an EHLO after STARTTLS
        # has done the TLS handshake. Alas, some clients do not do this,
        # and proceed directly to sending an AUTH command or something else.
        # If that happens, set state to WANT_AUTH and delegate.
        $self->{state} = WANT_AUTH;
        $self->_processAuth($command);
    }
}

sub _processAuth {
    my ($self, $command) = @_;
    my $commandName = $command->{command};
    if ($commandName eq 'AUTH') {
        if ($command->{mechanism} eq 'PLAIN') {
            if ($command->{initial}) {
                $self->_makeAuthPlainCallback($command->{initial});
            }
            else {
                # XXX Handle second line of auth
                $self->log->error('NYI multi-line AUTH');
            }
        }
        else {
            $self->stream->write(formatReply(504, 'Authentication mechanism not supported'));
        }
    }
    else {
        $self->stream->write(formatReply(530, 'Authentication required'));
    }
}

sub _makeAuthPlainCallback {
    my ($self, $base64) = @_;
    my @args = split "\0", decode_base64($base64);
    my $authCallback = $self->auth_plain;
    if ($authCallback) {
        my $promise = $authCallback->(@args);
        $promise->then(sub {
            $self->stream->write(formatReply(235, 'Authentication successful'));
            $self->log->debug('Successfully authenticated ' . $self->clientAddress);
        })->catch(sub {
            $self->stream->write(formatReply(535, 'Authentication credentials invalid'));
            $self->log->debug('Authentication failed for ' . $self->clientAddress);
        });
    }
    else {
        $self->log->warn('AUTH used but no auth callback set');
        $self->stream->write(formatReply(504, 'Authentication mechanism not supported'));
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
