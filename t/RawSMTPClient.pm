package RawSMTPClient;

# A minimal, scriptable SMTP client for tests. Unlike Mojo::SMTP::Client it
# writes whatever command line it is given, which is what lets the tests send
# ESMTP parameters such as NOTIFY= and inspect exactly what comes back.

use Mojo::Base -base, -signatures;
use Mojo::IOLoop;
use Mojo::IOLoop::Client;
use Mojo::IOLoop::Stream;
use Mojo::IOLoop::TLS;
use Mojo::Promise;
use MIME::Base64;

has [qw(address port stream)];

sub connect_p ($self) {
    my $promise = Mojo::Promise->new;
    my $client = Mojo::IOLoop::Client->new;
    $self->{client} = $client;
    $client->on(connect => sub ($client, $handle) {
        $self->_setStream(Mojo::IOLoop::Stream->new($handle));
        # Both outcomes have to be forwarded. Passing only the resolve
        # handler swallowed a rejected greeting and left the caller waiting.
        $self->expectReply_p->then(
            sub { $promise->resolve(@_) },
            sub { $promise->reject(@_) },
        );
    });
    $client->on(error => sub ($client, $err) { $promise->reject($err) });
    $client->connect(address => $self->address, port => $self->port);
    return $promise;
}

sub command_p ($self, $line) {
    $self->stream->write("$line\r\n");
    return $self->expectReply_p;
}

# Writes without waiting for a reply, for the lines of a DATA payload.
sub writeOnly ($self, $data) {
    $self->stream->write($data);
    return;
}

sub authPlain_p ($self, $username, $password) {
    my $token = encode_base64("\0$username\0$password", '');
    return $self->command_p("AUTH PLAIN $token");
}

sub startTLS_p ($self) {
    my $promise = Mojo::Promise->new;
    $self->stream->stop;
    my $tls = Mojo::IOLoop::TLS->new($self->stream->handle);
    $self->{tls} = $tls;
    $tls->on(upgrade => sub ($tls, $handle) {
        $self->_setStream(Mojo::IOLoop::Stream->new($handle));
        $promise->resolve;
    });
    $tls->on(error => sub ($tls, $err) { $promise->reject($err) });
    $tls->negotiate(
        address => $self->address,
        tls_options => { SSL_verify_mode => 0 },
    );
    return $promise;
}

sub close ($self) {
    $self->stream->close if $self->stream;
    return;
}

sub _setStream ($self, $stream) {
    $self->stream($stream);
    $self->{buffer} = '';
    $stream->on(read => sub ($stream, $bytes) {
        $self->{buffer} .= $bytes;
        $self->_tryComplete;
    });
    $stream->on(error => sub ($stream, $err) {
        $self->_abandon("stream error: $err");
    });
    # Mojo::IOLoop::Stream does not emit 'error' for either of these: an
    # inactivity timeout emits 'timeout' and then closes, and an EOF only
    # closes. Settling from 'error' alone left a pending reply unsettled for
    # good, so a server that stopped answering hung the test run instead of
    # failing it.
    $stream->on(timeout => sub ($stream) {
        $self->_abandon('timed out waiting for a reply');
    });
    $stream->on(close => sub ($stream) {
        $self->_abandon('connection closed before a reply arrived');
    });
    $stream->timeout(30);
    $stream->start;
}

# An SMTP reply is complete once a line arrives whose code is followed by a
# space rather than a hyphen.
sub _tryComplete ($self) {
    return unless $self->{pending};
    return unless $self->{buffer} =~ /\A(?:\d{3}-[^\n]*\n)*\d{3} [^\n]*\n/;
    my $reply = substr($self->{buffer}, 0, $+[0], '');
    (delete $self->{pending})->resolve($reply);
    return;
}

# Rejects whatever reply is outstanding. Harmless when none is, which is the
# ordinary case: a client that has read its 221 and closes has nothing pending.
sub _abandon ($self, $reason) {
    (delete $self->{pending})->reject($reason) if $self->{pending};
    return;
}

sub expectReply_p ($self) {
    my $promise = Mojo::Promise->new;
    $self->{pending} = $promise;
    $self->_tryComplete;
    return $promise;
}

1;
