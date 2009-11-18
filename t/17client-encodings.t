#!/usr/bin/perl -w

use strict;

use Test::More tests => 6;
use IO::Async::Test;
use IO::Async::Loop;
use IO::Async::Stream;

use Encode qw( encode_utf8 );

use Net::Async::IRC;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop->new();
testing_loop( $loop );

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

my @textmessages;

my $irc = Net::Async::IRC->new(
   handle => $S1,
   on_message => sub {
      my ( $self, $command, $message, $hints ) = @_;
      push @textmessages, [ $message, $hints ] if $command eq "text";
      return 1;
   },
   encoding => "UTF-8",
);

ok( defined $irc, 'defined $irc' );

$loop->add( $irc );

my $logged_in = 0;

$irc->login(
   nick => "MyNick",
   user => "me",
   realname => "My real name",
   on_login => sub { $logged_in = 1 },
);

my $serverstream = "";

wait_for_stream { $serverstream =~ m/$CRLF.*$CRLF/ } $S2 => $serverstream;

is( $serverstream, "USER me 0 * :My real name$CRLF" .
                   "NICK MyNick$CRLF", 'Server stream after client login' );

$S2->syswrite( ':irc.example.com 001 MyNick :Welcome to IRC MyNick!me@your.host' . $CRLF );

wait_for { $logged_in };

undef @textmessages;

my $helloworld = "مرحبا العالم"; # Hello World in Arabic, according to Google translate
my $octets = encode_utf8( $helloworld );

$S2->syswrite( ':Someone!theiruser@their.host PRIVMSG #arabic :' . $octets . $CRLF );

wait_for { @textmessages };

my ( $msg, $hints ) = @{ shift @textmessages };

is( $msg->command, "PRIVMSG",                      '$msg->command for PRIVMSG with encoding' );
is( $msg->prefix,  'Someone!theiruser@their.host', '$msg->prefix for PRIVMSG with encoding' );

is_deeply( $hints, { synthesized  => 1,
                     prefix_nick  => "Someone",
                     prefix_nick_folded => "someone",
                     prefix_user  => "theiruser",
                     prefix_host  => "their.host",
                     prefix_name  => "Someone",
                     prefix_name_folded => "someone",
                     prefix_is_me => '',
                     target_name  => "#arabic",
                     target_name_folded => "#arabic",
                     target_is_me => '',
                     target_type  => "channel",
                     is_notice    => 0,
                     restriction  => '',
                     text         => "مرحبا العالم",
                     handled      => 1 }, '$hints for PRIVMSG with encoding' );

$irc->send_message( "PRIVMSG", undef, "#arabic", "مرحبا العالم" );

$serverstream = "";
wait_for_stream { $serverstream =~ m/$CRLF/ } $S2 => $serverstream;

is( $serverstream, "PRIVMSG #arabic :$octets$CRLF",
                   "Server stream after sending PRIVMSG with encoding" );
