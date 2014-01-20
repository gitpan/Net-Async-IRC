#!/usr/bin/perl

use strict;
use warnings;

use Data::Dump 'pp';
use Getopt::Long;

use Future::Utils qw( repeat );
use IO::Async::Loop;
use Net::Async::IRC;

GetOptions(
   'server|s=s' => \my $SERVER,
   'nick|n=s'   => \my $NICK,
) or exit 1;

my $loop = IO::Async::Loop->new;

my $irc = Net::Async::IRC->new(
   on_message => sub {
      my ( $self, $command, $message, $hints ) = @_;
      return if $hints->{handled};

      printf "<<%s>>: %s\n", $command, join( " ", $message->args );
      print "| $_\n" for split m/\n/, pp( $hints );

      return 1;
   },
);
$loop->add( $irc );

$irc->login(
   host => $SERVER,
   nick => $NICK,
)->get;

my $stdin = IO::Async::Stream->new_for_stdin( on_read => sub {} );
$loop->add( $stdin );

my $eof;
( repeat {
   $stdin->read_until( "\n" )->on_done( sub {
      ( my $line, $eof ) = @_;
      return if $eof;

      chomp $line;
      my $message = Protocol::IRC::Message->new_from_line( $line );
      $irc->send_message( $message );
   });
} while => sub { !$_[0]->failure and !$eof } )->get;
