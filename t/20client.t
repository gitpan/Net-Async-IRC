#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my @messages;

my $irc = TestIRC->new;
sub write_irc
{
   my $line = $_[0];
   $irc->on_read( $line );
   length $line == 0 or die '$irc failed to read all of the line';
}

ok( defined $irc, 'defined $irc' );

write_irc( ':irc.example.com COMMAND arg1 arg2 :here is arg3' . $CRLF );

my ( $command, $msg, $hints );
( $command, $msg, $hints ) = @{ shift @messages };

is( $command, "COMMAND", '$command' );
is( $msg->command, "COMMAND", '$msg->command' );

is_deeply( [ $msg->args ], [ 'arg1', 'arg2', 'here is arg3' ], '$msg->args' );

done_testing;

package TestIRC;
use base qw( Protocol::IRC::Client );

sub new { return bless {}, shift }

sub nick { return "MyNick" }

sub on_message
{
   my $self = shift;
   my ( $command, $message, $hints ) = @_;
   push @messages, [ $command, $message, $hints ];
}
