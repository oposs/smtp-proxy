requires 'Mojolicious', '>= 9.48';
requires 'Getopt::Long';
requires 'Pod::Usage';
requires 'IO::Socket::SSL';
# Pinned exactly: SMTPProxy::RelayClient overrides two of this module's
# private command builders and reads two of its private instance fields,
# none of which are covered by its documented interface, so an upgrade is
# a change to code this distribution depends on line by line.
requires 'Mojo::SMTP::Client', '== 0.20';
requires 'Test::Exception';
requires 'EV';
# requires 'Devel::Cycle';
# requires 'PadWalker';