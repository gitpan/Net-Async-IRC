#!/usr/bin/perl -w

use strict;

use Test::More tests => 24;
use IO::Async::Test;
use IO::Async::Loop;
use IO::Async::Stream;

use Net::Async::IRC;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop->new();
testing_loop( $loop );

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

my @messages;

my $irc = Net::Async::IRC->new(
   transport => IO::Async::Stream->new( handle => $S1 ),
   on_message => sub {
      my ( $self, $command, $message, $hints ) = @_;
      # Only care about real events, not synthesized ones
      return 0 if $hints->{synthesized};
      push @messages, [ $command, $message, $hints ];
      return $command ne "NOTICE";
   },
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

my $m = shift @messages;

ok( defined $m, '$m defined after server reply' );

my ( $command, $msg, $hints ) = @$m;

is( $command, "001", '$command' );

isa_ok( $msg, "Net::Async::IRC::Message", '$msg isa Net::Async::IRC::Message' );

is( $msg->command, "001",             '$msg->command' );
is( $msg->prefix,  "irc.example.com", '$msg->prefix' );
is_deeply( [ $msg->args ], [ "MyNick", "Welcome to IRC MyNick!me\@your.host" ], '$msg->args' );

is_deeply( $hints, { prefix_nick  => undef,
                     prefix_nick_folded => undef,
                     prefix_user  => undef,
                     prefix_host  => "irc.example.com",
                     prefix_name  => "irc.example.com",
                     prefix_name_folded => "irc.example.com",
                     prefix_is_me => '',
                     text         => "Welcome to IRC MyNick!me\@your.host",
                     handled      => 1 }, '$hints' );

$S2->syswrite( ':Someone!theiruser@their.host PRIVMSG MyNick :Their message here' . $CRLF );

wait_for { @messages };

( $command, $msg, $hints ) = @{ shift @messages };

is( $msg->command, "PRIVMSG",                      '$msg->command for PRIVMSG' );
is( $msg->prefix,  'Someone!theiruser@their.host', '$msg->prefix for PRIVMSG' );

is_deeply( $hints, { prefix_nick  => "Someone",
                     prefix_nick_folded => "someone",
                     prefix_user  => "theiruser",
                     prefix_host  => "their.host",
                     prefix_name  => "Someone",
                     prefix_name_folded => "someone",
                     prefix_is_me => '',
                     targets      => "MyNick",
                     text         => "Their message here",
                     handled      => 1 }, '$hints for PRIVMSG' );

$S2->syswrite( ':MyNick!me@your.host PRIVMSG MyNick :Hello to me' . $CRLF );

wait_for { @messages };

( $command, $msg, $hints ) = @{ shift @messages };

is( $msg->command, "PRIVMSG",             '$msg->command for PRIVMSG to self' );
is( $msg->prefix,  'MyNick!me@your.host', '$msg->prefix for PRIVMSG to self' );

is_deeply( $hints, { prefix_nick  => "MyNick",
                     prefix_nick_folded => "mynick",
                     prefix_user  => "me",
                     prefix_host  => "your.host",
                     prefix_name  => "MyNick",
                     prefix_name_folded => "mynick",
                     prefix_is_me => 1,
                     targets      => "MyNick",
                     text         => "Hello to me",
                     handled      => 1 }, '$hints for PRIVMSG to self' );

$S2->syswrite( ':Someone!theiruser@their.host TOPIC #channel :Message of the day' . $CRLF );

wait_for { @messages };

( $command, $msg, $hints ) = @{ shift @messages };

is( $msg->command, "TOPIC",                        '$msg->command for TOPIC' );
is( $msg->prefix,  'Someone!theiruser@their.host', '$msg->prefix for TOPIC' );

is_deeply( $hints, { prefix_nick  => "Someone",
                     prefix_nick_folded => "someone",
                     prefix_user  => "theiruser",
                     prefix_host  => "their.host",
                     prefix_name  => "Someone",
                     prefix_name_folded => "someone",
                     prefix_is_me => '',
                     target_name  => "#channel",
                     target_name_folded => "#channel",
                     target_is_me => '',
                     target_type  => "channel",
                     text         => "Message of the day",
                     handled      => 1 }, '$hints for TOPIC' );

$S2->syswrite( ':Someone!theiruser@their.host NOTICE #channel :Please ignore me' . $CRLF );

wait_for { @messages };

( $command, $msg, $hints ) = @{ shift @messages };

is( $msg->command, "NOTICE",                       '$msg->command for NOTICE' );
is( $msg->prefix,  'Someone!theiruser@their.host', '$msg->prefix for NOTICE' );

is_deeply( $hints, { prefix_nick  => "Someone",
                     prefix_nick_folded => "someone",
                     prefix_user  => "theiruser",
                     prefix_host  => "their.host",
                     prefix_name  => "Someone",
                     prefix_name_folded => "someone",
                     prefix_is_me => '',
                     targets      => "#channel",
                     text         => "Please ignore me",
                     handled      => 0 }, '$hints for NOTICE' );

$S2->syswrite( ':Someone!theiruser@their.host NICK NewName' . $CRLF );

wait_for { @messages };

( $command, $msg, $hints ) = @{ shift @messages };

is( $msg->command, "NICK",                         '$msg->command for NICK' );
is( $msg->prefix,  'Someone!theiruser@their.host', '$msg->prefix for NICK' );

is_deeply( $hints, { prefix_nick  => "Someone",
                     prefix_nick_folded => "someone",
                     prefix_user  => "theiruser",
                     prefix_host  => "their.host",
                     prefix_name  => "Someone",
                     prefix_name_folded => "someone",
                     prefix_is_me => '',
                     old_nick     => "Someone",
                     old_nick_folded => "someone",
                     new_nick     => "NewName",
                     new_nick_folded => "newname",
                     handled      => 1 }, '$hints for NICK' );
