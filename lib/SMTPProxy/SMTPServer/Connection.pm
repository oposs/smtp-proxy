package SMTPProxy::SMTPServer::Connection;

use Mojo::Base -base;
use Mojo::IOLoop;
use Mojo::IOLoop::Stream;
use Mojo::IOLoop::TLS;
use Mojo::Promise;
use MIME::Base64;
use SMTPProxy::SMTPServer::CommandParser;
use SMTPProxy::SMTPServer::ReplyFormatter;

has [qw(loop stream id server clientAddress auth_plain mail rcpt data vrfy rset quit)];

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

        # If we have an active data eater, provide it to that.
        if ($self->{dataEater}) {
            $buffer = $self->{dataEater}->($buffer);
        }

        # Otherwise, try to parse a command.
        else {
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

    # QUIT, NOOP, and VRFY are valid in any state.
    if ($commandName eq 'QUIT') {
        my $callback = $self->quit;
        $self->log->debug("Processing QUIT for " . $self->clientAddress);
        $callback->() if $callback;
        $self->stream->write(
            formatReply(221, $self->server->service_name . 'Service closing transmission channel'),
            sub { Mojo::IOLoop->remove($self->id) });
    }
    elsif ($commandName eq 'NOOP') {
        $self->log->debug("Processing NOOP for " . $self->clientAddress);
        $self->stream->write(formatReply(250, 'OK'));
    }
    elsif ($commandName eq 'VRFY') {
        my $callback = $self->vrfy;
        $self->log->debug("Processing VRFY for " . $self->clientAddress);
        if ($callback) {
            say "in verify handler";
            $callback->($command->{string})
                ->then(sub {
                    $self->stream->write(formatReply(250, @_));
                })
                ->catch(sub {
                    $self->stream->write(formatReply(553, @_));
                });
        }
        else {
            $self->stream->write(formatReply(553, 'User ambiguous'));
        }
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
            'STARTTLS',
            ($self->server->require_starttls ? () : 'AUTH PLAIN')));
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
    elsif ($self->server->require_starttls) {
        $self->stream->write(formatReply(530, 'Must issue a STARTTLS command first'));
    }
    else {
        $self->{state} = WANT_AUTH;
        $self->_processAuth($command);
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
            $self->log->debug("Processing AUTH PLAIN for " . $self->clientAddress);
            if ($command->{initial}) {
                $self->_makeAuthPlainCallback($command->{initial});
            }
            else {
                $self->{dataEater} = sub {
                    my $buffer = shift;
                    if ($buffer =~ /^(.+)\r?\n$/) {
                        $self->{dataEater} = undef;
                        $self->_makeAuthPlainCallback($1);
                        return '';
                    }
                    elsif ($buffer =~ /\n/) {
                        $self->stream->write(formatReply(500,
                            'confused authentication response'));
                        return '';
                    }
                    else {
                        return $buffer;
                    }
                };
                $self->stream->write(formatReply(334, ''));
            }
        }
        else {
            $self->log->debug("Unsupported AUTH mechanism " . $command->{mechanism}.
                " used by " . $self->clientAddress);
            $self->stream->write(formatReply(504, 'Authentication mechanism not supported'));
        }
    }
    elsif ($self->server->require_auth) {
        $self->log->debug("Authentication required sent to " . $self->clientAddress);
        $self->stream->write(formatReply(530, 'Authentication required'));
    }
    else {
        $self->{state} = WANT_MAIL;
        $self->_processMail($command);
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
            $self->{state} = WANT_MAIL;
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

sub _processMail {
    my ($self, $command) = @_;
    if ($command->{command} eq 'MAIL') {
        my $promise = $self->mail->($command->{from}, $command->{parameters});
        $promise->then(sub {
            $self->stream->write(formatReply(250, 'OK'));
            $self->log->debug('Accepted MAIL command from ' . $self->clientAddress);
            $self->{state} = WANT_RCPT;
        })->catch(sub {
            my $error = shift;
            $self->stream->write(formatReply(553,
                'Requested action not taken: ' . $error));
            $self->log->debug('MAIL command rejected for ' . $self->clientAddress);
        });
    }
    else {
        $self->stream->write(formatReply(503, 'Bad sequence of commands'));
    }
}

sub _processRcpt {
    my ($self, $command) = @_;
    if ($command->{command} eq 'RCPT') {
        my $promise = $self->rcpt->($command->{to}, $command->{parameters});
        $promise->then(sub {
            $self->stream->write(formatReply(250, 'OK'));
            $self->log->debug('Accepted RCPT command from ' . $self->clientAddress);
            $self->{state} = WANT_DATA;
        })->catch(sub {
            my $error = shift;
            $self->stream->write(formatReply(550,
                'Will not send mail to this user: ' . $error));
            $self->log->debug('RCPT command rejected for ' . $self->clientAddress);
        });
    }
    else {
        $self->stream->write(formatReply(503, 'Bad sequence of commands'));
    }
}

sub _processData {
    my ($self, $command) = @_;
    if ($command->{command} eq 'RCPT') {
        # An extra recipient; fine.
        $self->_processRcpt($command);
    }
    elsif ($command->{command} eq 'DATA') {
        my $headersPromise = Mojo::Promise->new;
        my $bodyPromise = Mojo::Promise->new;
        my $promise = $self->data->($headersPromise, $bodyPromise);
        my $headersDone = 0;
        my $handled = '';
        $self->{dataEater} = sub {
            my $buffer = shift;
            for my $line (split(/(?<=\n)/, $buffer)) {
                # Defer handling incomplete lines.
                return $line unless $line =~ /\n$/;

                # If it's a '.' then it's the end of the message.
                if ($line =~ /^\.\r?\n$/) {
                    if (!$headersDone) {
                        $headersPromise->resolve($handled);
                        $bodyPromise->resolve('');
                    }
                    else {
                        $bodyPromise->resolve($handled);
                    }
                    $self->{dataEater} = '';
                    $promise
                        ->then(sub {
                            $self->stream->write(formatReply(250, 'OK'));
                            $self->{state} = WANT_MAIL;
                            $self->log->debug('Accepted MAIL command for ' . $self->clientAddress);
                        })
                        ->catch(sub {
                            my $message = shift;
                            $self->stream->write(formatReply(550, $message // ''));
                            $self->log->debug('MAIL command rejected for ' . $self->clientAddress);
                            $self->{state} = WANT_MAIL;
                        });
                }

                # If we're awaiting headers and we get an empty line, then
                # we're done with the headers.
                elsif (!$headersDone && $line =~ /^\r?\n$/) {
                    $headersPromise->resolve($handled);
                    $handled = '';
                    $headersDone = 1;
                }

                # Otherwise, it's just a line to collect.
                else {
                    $line =~ s/^\.//g;
                    $handled .= $line;
                }
            }
        };
        $self->stream->write(formatReply(354, ''));
    }
    else {
        $self->stream->write(formatReply(503, 'Bad sequence of commands'));
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
