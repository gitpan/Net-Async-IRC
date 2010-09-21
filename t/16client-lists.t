#!/usr/bin/perl -w

use strict;

use Test::More tests => 6;
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
      # Only care about synthesized events, not real ones
      return 0 unless $hints->{synthesized};
      push @messages, [ $command, $message, $hints ];
      return 1;
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

undef @messages;

$S2->syswrite( ':irc.example.com 375 MyNick :- Here is the Message Of The Day -' . $CRLF .
               ':irc.example.com 372 MyNick :- some more of the message -' . $CRLF .
               ':irc.example.com 376 MyNick :End of /MOTD command.' . $CRLF );

wait_for { @messages };

my ( $command, $msg, $hints );

( $command, $msg, $hints ) = @{ shift @messages };

is( $command, "motd", '$command for motd' );

is_deeply( $hints, { prefix_nick  => undef,
                     prefix_nick_folded => undef,
                     prefix_user  => undef,
                     prefix_host  => "irc.example.com",
                     prefix_name  => "irc.example.com",
                     prefix_name_folded => "irc.example.com",
                     prefix_is_me => '',
                     motd         => [
                        '- Here is the Message Of The Day -',
                        '- some more of the message -',
                     ],
                     synthesized  => 1,
                     handled      => 1 }, '$hints for names' );

undef @messages;

$S2->syswrite( ':irc.example.com 353 MyNick = #channel :@Some +Users Here' . $CRLF .
               ':irc.example.com 366 MyNick #channel :End of NAMES list' . $CRLF );

wait_for { @messages };

( $command, $msg, $hints ) = @{ shift @messages };

is( $command, "names", '$command for names' );

is_deeply( $hints, { prefix_nick  => undef,
                     prefix_nick_folded => undef,
                     prefix_user  => undef,
                     prefix_host  => "irc.example.com",
                     prefix_name  => "irc.example.com",
                     prefix_name_folded => "irc.example.com",
                     prefix_is_me => '',
                     target_name  => '#channel',
                     target_name_folded => '#channel',
                     target_type  => 'channel',
                     target_is_me => '',
                     names        => {
                        some  => { nick => "Some",  flag => '@' },
                        users => { nick => "Users", flag => '+' },
                        here  => { nick => "Here",  flag => '' },
                     },
                     synthesized  => 1,
                     handled      => 1 }, '$hints for names' );
