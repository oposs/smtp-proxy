package SMTPProxy::SMTPServer::Connection;

use Mojo::Base -base, -signatures;
use Mojo::IOLoop;
use Mojo::IOLoop::Stream;
use Mojo::IOLoop::TLS;
use Mojo::Promise;
use MIME::Base64;
use SMTPProxy::SMTPServer::CommandParser;
use SMTPProxy::SMTPServer::DsnParameters;
use SMTPProxy::SMTPServer::ReplyFormatter;
use Scalar::Util qw(weaken);

has [qw(service_name require_starttls tls_cert tls_key require_auth
     id log credentials clientAddress auth mail rcpt data vrfy rset quit
    smtplogHandle stream dataEater setupCallback state tlsActive)];


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

has state => sub ($self) {
    return WANT_INITIAL_EHLO;
};

sub new ($class, %args) {
    my $self = $class->SUPER::new(%args);
    $self->_sendReply(220, $self->service_name . ' SMTP service ready');
    $self->_setupReader;
    $self->_setupClose;
    $self->setupCallback->($self);
    return $self;
}

sub _setupClose ($self) {
    # Capture the id and the log rather than the connection. A stream is torn
    # down as part of destroying the connection that owns it, and closing a
    # stream emits 'close', so a handler holding a weak reference to the
    # connection can be called just as that reference falls away. Nothing here
    # needs the object itself, and neither the id nor the log refers back to
    # it, so holding them strongly avoids the question entirely.
    my $id = $self->id;
    my $log = $self->log;
    my $clientAddress = $self->clientAddress;

    $self->stream->on('close' => sub ($stream) {
            Mojo::IOLoop->remove($id);
        }
    );

    $self->stream->on('error' => sub ($stream, $err) {
            $log->error("Error on stream for $clientAddress: $err");
        }
    );

    $self->stream->on('timeout' => sub ($stream) {
            # https://docs.mojolicious.org/Mojo/IOLoop/Stream#timeout
            $log->error("Timeout on stream for $clientAddress");
        }
    );
}

sub _setupReader ($self) {
    my $buffer = '';
    my $mb_logged = 1;
    # A fresh reader starts idle. This matters after a STARTTLS upgrade: the
    # reader that handled the STARTTLS deliberately stops without clearing the
    # flag, and its replacement would otherwise find the connection marked busy
    # for good and never process anything.
    $self->{draining} = 0;
    weaken $self;
    $self->stream->on(read => sub ($stream, $bytes) {
        $buffer .= $bytes;
        $self->_drain(\$buffer, \$mb_logged);
    });
}

# Everything that has arrived is processed before the reader goes idle, rather
# than one command per read event. A client is allowed to put a group of
# commands in one write (RFC 2920) and then read the replies, so a reader that
# parses once and stops answers the first command and waits for bytes that the
# client, waiting for replies, will never send.
#
# One at a time, though, and never overlapping. The state a command is judged
# against is read here, and it is written from the promise callbacks the
# handlers install, which run on a later tick. Dispatching a whole packet at
# once would judge a RCPT against the state that the MAIL in front of it had
# not finished writing -- the RCPT drawing 503, and the two replies coming back
# in the wrong order, which RFC 2920 forbids. So each command's promise has to
# settle before the next one is dispatched.
sub _drain ($self, $bufferRef, $mbRef) {
    return if $self->{draining};
    $self->{draining} = 1;
    $self->_drainStep($bufferRef, $mbRef);
    return;
}

sub _drainStep ($self, $bufferRef, $mbRef) {
    weaken $self;
    while (ref $self) {
        # A data eater owns the whole buffer while it is installed.
        if ($self->dataEater) {
            my $mb = sprintf("%.1f", length($$bufferRef) / 1e6)+0;
            if ($mb > $$mbRef) {
                $self->log->debug("received $mb MB data");
                $$mbRef++;
            }
            $$bufferRef = $self->dataEater->($$bufferRef) // '';
            return if $self->_resumeWhenCommandCompletes($bufferRef, $mbRef);
            # An eater that has finished hands back whatever was not its own
            # data, which is a command; one that has not wants more bytes.
            next if !$self->dataEater && length $$bufferRef;
            last;
        }

        my $initialBuffer = $$bufferRef;
        (my $command, $$bufferRef) = parseCommand($$bufferRef);
        $self->_logIncoming($initialBuffer, $$bufferRef) if $self->smtplogHandle;
        last unless $command;

        if ($command->{error}) {
            $self->_sendReply(
                $command->{suggested_reply} // 500,
                $command->{error}
            );
            next;
        }

        # STARTTLS is where draining has to stop rather than continue. Whatever
        # else is in the buffer arrived in the clear, before the handshake, and
        # an attacker who can write to the plaintext connection can put
        # commands there; carrying on would run them as though the client had
        # sent them inside the TLS session, which is CVE-2011-0411. The buffer
        # is dropped explicitly and this reader stops for good -- a successful
        # upgrade installs a new one, with a buffer of its own.
        if ($command->{command} eq 'STARTTLS') {
            if (length $$bufferRef) {
                $self->log->info('Discarding ' . length($$bufferRef) .
                    ' byte(s) received before STARTTLS from ' .
                    $self->clientAddress);
                $$bufferRef = '';
            }
            $self->_processCommand($command);
            return;
        }

        $self->_resumeAfter($self->_processCommand($command), $bufferRef, $mbRef);
        return;
    }
    $self->{draining} = 0 if ref $self;
    return;
}

# A data eater that has finished its message leaves the promise for the command
# it completed here, so that the commands behind it wait for the reply.
sub _resumeWhenCommandCompletes ($self, $bufferRef, $mbRef) {
    my $completion = delete $self->{commandCompletion} or return 0;
    $self->_resumeAfter($completion, $bufferRef, $mbRef);
    return 1;
}

sub _resumeAfter ($self, $completion, $bufferRef, $mbRef) {
    weaken $self;
    my $resume = sub {
        $self->_drainStep($bufferRef, $mbRef) if ref $self;
        return;
    };
    # Both arms, rather than finally: a handler that rejects has already dealt
    # with it by sending its own reply, and letting that rejection travel on
    # from here would only produce an unhandled one.
    $completion->then($resume, $resume);
    return;
}

sub _logIncoming ($self, $initialBuffer, $remainder) {
    my $parsed = substr($initialBuffer, 0,
        length($initialBuffer) - length($remainder));
    # The AUTH argument carries the credentials, so it is redacted
    # unless we were asked to log them. This matches the raw line
    # rather than the parse: RFC 4954 section 2 makes the verb and
    # the mechanism name case insensitive, so the bytes need not be
    # spelled the way the parser reports them, and a line we failed
    # to parse at all can still hold a secret.
    if (!$self->credentials) {
        $parsed =~ s/^(AUTH\s+\S+\s+).+$/$1\[REDACTED]/i;
    }
    $self->_writeSmtpLogEntry(0, $parsed);
    return;
}

sub _sendReply ($self, $code, @args) {
    my $p = Mojo::Promise->new;
    my $reply = formatReply($code, @args);
    if ($self->smtplogHandle) {
        $self->_writeSmtpLogEntry(1, $reply);
    }
    $self->stream->write($reply, sub { $p->resolve(@_) });
    return $p;
}

sub _writeSmtpLogEntry ($self, $sent, $entry) {
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
    my $timestamp = sprintf "%4d-%02d-%02d %02d:%02d:%02d", $year + 1900, $mon + 1,
        $mday, $hour, $min, $sec;
    my $leader = $sent ? "<<<" : ">>>";
    my $handle = $self->smtplogHandle;
    $entry =~ s/\r?\n$//;
    for (split /\r?\n/, $entry) {
        say $handle $self->id . " $timestamp $leader $_";
    }
    flush $handle;
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

sub _processCommand ($self, $command) {
    my $commandName = $command->{command};

    # QUIT, NOOP, VRFY, EHLO and HELO are valid in any state.
    if ($commandName eq 'QUIT') {
        my $callback = $self->quit;
        $self->log->debug("Processing QUIT for " . $self->clientAddress);
        $callback->() if $callback;
        $self->_sendReply(221,
            $self->service_name . ' closing transmission channel');
        $self->stream->close_gracefully;
        # Nothing follows a QUIT. A promise that never settles parks the
        # reader here, rather than letting it answer commands the client had
        # no business sending once it had ended the session.
        return Mojo::Promise->new;
    }
    elsif ($commandName eq 'NOOP') {
        $self->log->debug("Processing NOOP for " . $self->clientAddress);
        return $self->_sendReply(250, 'OK');
    }
    elsif ($commandName eq 'VRFY') {
        my $callback = $self->vrfy;
        $self->log->debug("Processing VRFY for " . $self->clientAddress);
        if ($callback) {
            return $callback->($command->{string})
                ->then(
                    sub {
                        $self->_sendReply(250, @_);
                    },
                    sub {
                        $self->_sendReply(553, @_);
                    });
        }
        return $self->_sendReply(553, 'User ambiguous');
    }
    elsif ($commandName eq 'EHLO' || $commandName eq 'HELO') {
        $self->log->debug("Processing $commandName for " . $self->clientAddress);
        return $self->_processGreeting($command);
    }
    elsif ($commandName eq 'RSET') {
        my $callback = $self->rset;
        $self->log->debug("Processing RSET for " . $self->clientAddress);
        $callback->() if $callback;
        if ($self->state > WANT_MAIL) {
            $self->state(WANT_MAIL);
        }
        return $self->_sendReply(250, 'OK');
    }
    else {
        # Go by state.
        my $methodName = $STATE_METHODS[$self->state];
        return $self->$methodName($command);
    }
}

# RFC 5321 4.1.4: a client may issue EHLO or HELO at any point in a session,
# and an acceptable one clears all buffers and resets the state exactly as if
# RSET had been issued. Greetings used to be dispatched by state like every
# other command, so they were only accepted in the two states that expected
# one; a second EHLO drew 530 in WANT_AUTH and 503 in the mail states. Sending
# one to start over after a rejected transaction is a normal client idiom.
#
# What it resets is the transaction, not the session. RFC 4954 section 4 ties
# authentication to the session, and there is no way for the client to
# authenticate a second time in any case, so a client that has logged in comes
# back to WANT_MAIL rather than to WANT_AUTH.
sub _processGreeting ($self, $command) {
    my $tlsEstablished = $self->tlsActive;
    my @extensions;
    if ($command->{command} eq 'EHLO') {
        push @extensions, 'STARTTLS' unless $tlsEstablished;
        push @extensions, 'AUTH PLAIN LOGIN'
            if $tlsEstablished || !$self->require_starttls;
        push @extensions, 'DSN';
    }
    # HELO is basic SMTP: a single line, and no extension keywords, since the
    # client has not asked whether we speak any (RFC 5321 4.1.1.1).
    my $reply = $self->_sendReply(250,
        $self->service_name . ($tlsEstablished
            ? ' offers another warm hug of welcome'
            : ' offers a warm hug of welcome'),
        @extensions);

    # Reset the transaction the way RSET does -- but only when there is one to
    # reset. A greeting is also how a session opens and how it resumes after
    # STARTTLS, and reporting a transaction boundary to the application for
    # those would be inventing an event that did not happen.
    my $state = $self->state;
    if ($state >= WANT_MAIL) {
        my $callback = $self->rset;
        $callback->() if $callback;
    }

    $self->state(
        $state >= WANT_MAIL ? WANT_MAIL       :
        $state >= WANT_AUTH ? WANT_AUTH       :
        $tlsEstablished     ? WANT_AUTH       :
                              WANT_STARTTLS);
    return $reply;
}

# Greetings are handled above, before the dispatch by state, so anything
# arriving in this state is genuinely out of sequence.
sub _processInitialEhlo ($self, $command) {
    return $self->_sendReply(503, 'Bad sequence of commands');
}

sub _processStartTLS ($self, $command) {
    my $commandName = $command->{command};
    if ($commandName eq 'STARTTLS') {
        # Held strongly, and read from in the failure paths instead of $self,
        # for the same reason _setupClose does it: closing the stream is what
        # destroys the connection that owns it, and $self is weakened by the
        # time these run, so anything read from it after the close runs on
        # undef and takes the reactor's I/O watcher down with it. The stream is
        # captured here rather than fetched later because the successful path
        # replaces it with the upgraded one.
        my $id = $self->id;
        my $log = $self->log;
        my $clientAddress = $self->clientAddress;
        my $stream = $self->stream;
        return $self->_sendReply(220, 'Go ahead')->then(sub {
            my $tls = Mojo::IOLoop::TLS->new($stream->handle);
            weaken $self;
            $tls->on(upgrade => sub ($tls, $new_handle) {
                $self->log->debug("Successful TLS upgrade for " . $self->clientAddress);
                $self->stream(Mojo::IOLoop::Stream->new($new_handle));
                # timeout a stream after 10 minutes not after 15 seconds
                # https://docs.mojolicious.org/Mojo/IOLoop/Stream#timeout
                $self->stream->timeout(600);
                $self->tlsActive(1);
                $self->state(WANT_TLS_EHLO);
                $self->_setupReader;
                $self->stream->start;
                $self->_setupClose;
            });
            $tls->on(error => sub ($tls, $err) {
                $log->info("Failed TLS upgrade for $clientAddress: $err");
                # Nothing of $self may be read after this line.
                $stream->emit('error', $err)->close;
                Mojo::IOLoop->remove($id);
            });
            $tls->negotiate(
                server => 1,
                tls_cert => $self->tls_cert,
                tls_key => $self->tls_key
            );
            $self->log->debug("Starting TLS upgrade for " . $self->clientAddress);
        })->catch(sub ($err) {
            $log->info("Failed to TLS for $clientAddress: $err");
            $stream->emit('error', $err)->close;
            Mojo::IOLoop->remove($id);
        });
    }
    elsif ($self->require_starttls) {
        return $self->_sendReply(530, 'Must issue a STARTTLS command first');
    }
    else {
        $self->state(WANT_AUTH);
        return $self->_processAuth($command);
    }
}

sub _processTLSEhlo ($self, $command) {
    # RFC 3207 says that the client SHOULD send an EHLO after STARTTLS has done
    # the TLS handshake. Alas, some clients do not do this, and proceed
    # directly to sending an AUTH command or something else. A greeting is
    # handled before the dispatch by state, so whatever arrives here is one of
    # those and belongs to the next state.
    $self->state(WANT_AUTH);
    return $self->_processAuth($command);
}

sub _processAuth ($self, $command) {
    my $commandName = $command->{command};
    if ($commandName eq 'AUTH') {
        if ($command->{mechanism} eq 'PLAIN') {
            $self->log->debug("Processing AUTH PLAIN for " . $self->clientAddress);
            if ($command->{initial}) {
                return $self->_makeAuthPlainCallback($command->{initial});
            }
            else {
                weaken $self;
                $self->dataEater(sub ($buffer) {
                    if ($buffer =~ /^(.+?)\r?\n$/) {
                        my $auth = $1;
                        $self->dataEater(undef);
                        $self->_logAuthenticationData($auth);
                        $self->{commandCompletion} =
                            $self->_makeAuthPlainCallback($auth);
                        return '';
                    }
                    elsif ($buffer =~ /\n/) {
                        $self->_sendReply(500, 'confused authentication response');
                        return '';
                    }
                    else {
                        return $buffer;
                    }
                });
                return $self->_sendReply(334, '');
            }
        }
        elsif ($command->{mechanism} eq 'LOGIN') {
            $self->log->debug("Processing AUTH LOGIN for " . $self->clientAddress);
            my $usernameBase64;
            weaken $self;
            $self->dataEater(sub ($buffer) {
                if ($buffer =~ /^(.+?)\r?\n$/) {
                    my $auth = $1;
                    $self->_logAuthenticationData($auth);
                    if ($usernameBase64) {
                        my $passwordBase64 = $auth;
                        $self->log->debug("Received AUTH LOGIN password for " .
                            $self->clientAddress);
                        $self->dataEater(undef);
                        $self->{commandCompletion} = $self->_makeAuthLoginCallback(
                            $usernameBase64, $passwordBase64);
                        return '';
                    }
                    else {
                        
                        $self->log->debug("Received AUTH LOGIN username (".decode_base64($auth).") for " .
                            $self->clientAddress);
                        $usernameBase64 = $auth;
                        $self->_sendReply(334, encode_base64('Password:', ''));
                        return '';
                    }
                }
                elsif ($buffer =~ /\n/) {
                    $self->_sendReply(500, 'confused authentication response');
                    return '';
                }
                else {
                    return $buffer;
                }
            });
            return $self->_sendReply(334, encode_base64('Username:', ''));
        }
        else {
            $self->log->debug("Unsupported AUTH mechanism " . $command->{mechanism}.
                " used by " . $self->clientAddress);
            return $self->_sendReply(504,
                'Authentication mechanism not supported');
        }
    }
    elsif ($self->require_auth) {
        $self->log->debug("Authentication required sent to " . $self->clientAddress);
        return $self->_sendReply(530, 'Authentication required');
    }
    else {
        $self->state(WANT_MAIL);
        return $self->_processMail($command);
    }
}

sub _logAuthenticationData ($self, $auth) {
    if ($self->smtplogHandle) {
        $self->_writeSmtpLogEntry(0, $self->credentials ? $auth : '[REDACTED]');
    }
}

sub _makeAuthPlainCallback ($self, $base64) {
    return $self->_makeAuthCallback(split "\0", decode_base64($base64));
}

sub _makeAuthLoginCallback ($self, $usernameBase64, $passwordBase64) {
    return $self->_makeAuthCallback('', decode_base64($usernameBase64),
        decode_base64($passwordBase64));
}

sub _makeAuthCallback ($self, @args) {
    my $authCallback = $self->auth;
    if ($authCallback) {
        my $promise = $authCallback->(@args);
        return $promise->then(
            sub {
                $self->_sendReply(235, 'Authentication successful');
                $self->log->debug('Successfully authenticated ' . $self->clientAddress);
                $self->state(WANT_MAIL);
            },
            sub {
                $self->_sendReply(535, 'Authentication credentials invalid');
                $self->log->debug('Authentication failed for ' . $self->clientAddress);
            });
    }
    $self->log->warn('AUTH used but no auth callback set');
    return $self->_sendReply(504, 'Authentication mechanism not supported');
}

# We announce DSN, so RFC 3461 section 5.1 obliges us to answer 501 to a
# parameter that does not meet its grammar -- here, at the command that carried
# it, rather than by handing it to the upstream and discovering it after the
# client has transferred a whole message body.
# Returns the promise for the 501 it sent, or undef if the parameters were
# acceptable. A promise, rather than a flag, because the caller has to hand one
# back to the reader either way.
sub _rejectBadDsnParameters ($self, $command, $which) {
    my $error = validateDsnParameters($command->{parameters}, $which);
    return undef unless $error;
    $self->log->debug("Rejected $which parameters from " .
        $self->clientAddress . ": $error");
    return $self->_sendReply(501, $error);
}

sub _processMail ($self, $command) {
    if ($command->{command} eq 'MAIL') {
        if (my $rejected = $self->_rejectBadDsnParameters($command, 'MAIL')) {
            return $rejected;
        }
        my $promise = $self->mail->($command->{from}, $command->{parameters});
        return $promise->then(
            sub {
                $self->_sendReply(250, 'OK');
                $self->log->debug('Accepted MAIL command from ' . $self->clientAddress);
                $self->state(WANT_RCPT);
            },
            sub {
                my $error = shift;
                $self->_sendReply(553,
                    'Requested action not taken: ' . $error);
                $self->log->debug('MAIL command rejected for ' . $self->clientAddress);
            });
    }
    return $self->_sendReply(503, 'Bad sequence of commands');
}

sub _processRcpt  ($self, $command)  {
    if ($command->{command} eq 'RCPT') {
        if (my $rejected = $self->_rejectBadDsnParameters($command, 'RCPT')) {
            return $rejected;
        }
        my $promise = $self->rcpt->($command->{to}, $command->{parameters});
        return $promise->then(
            sub {
                $self->_sendReply(250, 'OK');
                $self->log->debug('Accepted RCPT command from ' . $self->clientAddress);
                $self->state(WANT_DATA);
            },
            sub {
                my $error = shift;
                $self->_sendReply(550,
                    'Will not send mail to this user: ' . $error);
                $self->log->debug('RCPT command rejected for ' . $self->clientAddress);
            });
    }
    return $self->_sendReply(503, 'Bad sequence of commands');
}

sub _processData ($self, $command) {
    if ($command->{command} eq 'RCPT') {
        # An extra recipient; fine.
        return $self->_processRcpt($command);
    }
    elsif ($command->{command} eq 'DATA') {
        my $headersPromise = Mojo::Promise->new;
        my $bodyPromise = Mojo::Promise->new;
        my $promise = $self->data->($headersPromise, $bodyPromise);
        my $headersDone = 0;
        my $handled = '';
        # Held strongly: the client may hang up while the relay is still in
        # flight, and these are then all that is left to report it with.
        my $log = $self->log;
        my $clientAddress = $self->clientAddress;
        weaken $self;
        $self->dataEater(sub ($buffer) {
            while (length $buffer) {
                # An incomplete line has no terminator yet; hold it until the
                # rest of it arrives.
                last unless $buffer =~ /\A([^\n]*\n)/;
                my $line = $1;

                # A lone dot ends the message.
                if ($line =~ /\A\.\r?\n\z/) {
                    substr($buffer, 0, length($line), '');
                    if (!$headersDone) {
                        $self->log->debug("Header received (empty Body). Resolving Header Promise and Empty Body Promise.");
                        $headersPromise->resolve($handled);
                        $bodyPromise->resolve('');
                    }
                    else {
                        $self->log->debug('Body received '. length($handled) . ' Bytes. Resolving Body Promise.');
                        $bodyPromise->resolve($handled);
                    }
                    $self->dataEater(undef);
                    $self->{commandCompletion} = $promise->then(
                        sub ($message = '???') {
                            # Nobody left to reply to; rejecting here would
                            # only produce an unhandled rejection.
                            unless (ref $self) {
                                $log->info("Client $clientAddress left before " .
                                    "the message could be accepted: $message");
                                return;
                            }
                            $self->_sendReply(250, 'OK: ' . $message);
                            $self->state(WANT_MAIL);
                            $log->debug("Accepted DATA for $clientAddress $message");
                            return;
                        }
                    )->catch(sub ($message = undef) {
                            $message //= '';
                            unless (ref $self) {
                                $log->info("Client $clientAddress left before " .
                                    "the rejection could be sent: $message");
                                return;
                            }
                            $self->_sendReply(550, $message);
                            $log->debug("DATA rejected for $clientAddress $message");
                            $self->state(WANT_MAIL);
                            return;
                        }
                    );
                    # Whatever the client wrote after the terminator belongs to
                    # the session rather than to the message, so it is handed
                    # back for the reader to dispatch as commands. It used to
                    # be fed into the finished message and then dropped along
                    # with the rest of the buffer, so a client that wrote the
                    # dot and its QUIT in one packet was answered 250 and then
                    # nothing at all, and sat there until it timed out.
                    return $buffer;
                }

                substr($buffer, 0, length($line), '');

                # If we're awaiting headers and we get an empty line, then
                # we're done with the headers.
                if (!$headersDone && $line =~ /\A\r?\n\z/) {
                    $self->log->debug("Header received. Resolving Header Promise");
                    $headersPromise->resolve($handled);
                    $handled = '';
                    $headersDone = 1;
                }

                # Otherwise, it's just a line to collect.
                else {
                    $line =~ s/^\.//;
                    $handled .= $line;
                }
            }
            return $buffer;
        });
        return $self->_sendReply(354, 'End data with <CR><LF>.<CR><LF>');
    }
    return $self->_sendReply(503, 'Bad sequence of commands');
}

sub DESTROY ($self) {
    $self->log && $self->log->debug(__PACKAGE__ . " destroyed");
    return;
};

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
