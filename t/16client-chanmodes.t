#!/usr/bin/perl -w

use strict;

use Test::More tests => 17;
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
   handle => $S1,
   on_message => sub {
      my ( $self, $command, $message, $hints ) = @_;
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
   on_login => sub {}, # ignore
);

my $serverstream = "";

wait_for_stream { $serverstream =~ m/$CRLF.*$CRLF/ } $S2 => $serverstream;

is( $serverstream, "USER me 0 * :My real name$CRLF" .
                   "NICK MyNick$CRLF", 'Server stream after client login' );

$S2->syswrite( ':irc.example.com 001 MyNick :Welcome to IRC MyNick!me@your.host' . $CRLF );

$S2->syswrite( ':irc.example.com 005 MyNick NAMESX PREFIX=(ohv)@%+ CHANMODES=beI,k,l,imnpst :are supported by this server' . $CRLF );

wait_for { defined $irc->isupport( "NAMESX" ) };

undef @messages;

$S2->syswrite( ':Someone!theiruser@their.host MODE #chan +i' . $CRLF );

wait_for { @messages };

my ( $command, $msg, $hints );
my $modes;

( $command, $msg, $hints ) = @{ shift @messages };

is( $msg->command, "MODE",                         '$msg->command for +i' );
is( $msg->prefix,  'Someone!theiruser@their.host', '$msg->prefix for +i' );
is_deeply( [ $msg->args ], [ "#chan", "+i" ],      '$msg->args for +i' );

is_deeply( $hints, { prefix_nick  => "Someone",
                     prefix_nick_folded => "someone",
                     prefix_user  => "theiruser",
                     prefix_host  => "their.host",
                     prefix_name  => "Someone",
                     prefix_name_folded => "someone",
                     prefix_is_me => '',
                     target_name  => "#chan",
                     target_name_folded => "#chan",
                     target_is_me => '',
                     target_type  => "channel",
                     modechars    => "+i",
                     modeargs     => [ ],
                     modes        => [
                        { type => 'bool', sense => 1, mode => "i" },
                     ],
                     handled      => 1 }, '$hints for +i' );

$S2->syswrite( ':Someone!theiruser@their.host MODE #chan -i' . $CRLF );

wait_for { @messages };

( $command, $msg, $hints ) = @{ shift @messages };
$modes = $hints->{modes};

is_deeply( $modes,
           [ { type => 'bool', sense => -1, mode => "i" } ],
           '$modes for -i' );

$S2->syswrite( ':Someone!theiruser@their.host MODE #chan +b *!bad@bad.host' . $CRLF );

wait_for { @messages };

( $command, $msg, $hints ) = @{ shift @messages };
$modes = $hints->{modes};

is_deeply( $modes,
           [ { type => 'list', sense => 1, mode => "b", value => "*!bad\@bad.host" } ],
           '$modes for +b ...' );

$S2->syswrite( ':Someone!theiruser@their.host MODE #chan -b *!less@bad.host' . $CRLF );

wait_for { @messages };

( $command, $msg, $hints ) = @{ shift @messages };
$modes = $hints->{modes};

is_deeply( $modes,
           [ { type => 'list', sense => -1, mode => "b", value => "*!less\@bad.host" }, ],
           '$hints for -b ...' );

$S2->syswrite( ':Someone!theiruser@their.host MODE #chan +o OpUser' . $CRLF );

wait_for { @messages };

( $command, $msg, $hints ) = @{ shift @messages };
$modes = $hints->{modes};

is_deeply( $modes, 
           [ { type => 'occupant', sense => 1, mode => "o", flag => '@', nick => "OpUser", nick_folded => "opuser" } ],
           '$modes[chanmode] for +o OpUser' );

$S2->syswrite( ':Someone!theiruser@their.host MODE #chan -o OpUser' . $CRLF );

wait_for { @messages };

( $command, $msg, $hints ) = @{ shift @messages };
$modes = $hints->{modes};

is_deeply( $modes, 
           [ { type => 'occupant', sense => -1, mode => "o", flag => '@', nick => "OpUser", nick_folded => "opuser" } ],
           '$modes[chanmode] for -o OpUser' );

$S2->syswrite( ':Someone!theiruser@their.host MODE #chan +k joinkey' . $CRLF );

wait_for { @messages };

( $command, $msg, $hints ) = @{ shift @messages };
$modes = $hints->{modes};

is_deeply( $modes, 
           [ { type => 'value', sense => 1, mode => "k", value => "joinkey" } ],
           '$modes[chanmode] for +k joinkey' );

$S2->syswrite( ':Someone!theiruser@their.host MODE #chan -k joinkey' . $CRLF );

wait_for { @messages };

( $command, $msg, $hints ) = @{ shift @messages };
$modes = $hints->{modes};

is_deeply( $modes, 
           [ { type => 'value', sense => -1, mode => "k", value => "joinkey" } ],
           '$modes[chanmode] for -k joinkey' );

$S2->syswrite( ':Someone!theiruser@their.host MODE #chan +l 30' . $CRLF );

wait_for { @messages };

( $command, $msg, $hints ) = @{ shift @messages };
$modes = $hints->{modes};

is_deeply( $modes, 
           [ { type => 'value', sense => 1, mode => "l", value => "30" } ],
           '$modes[chanmode] for +l 30' );

$S2->syswrite( ':Someone!theiruser@their.host MODE #chan -l' . $CRLF );

wait_for { @messages };

( $command, $msg, $hints ) = @{ shift @messages };
$modes = $hints->{modes};

is_deeply( $modes, 
           [ { type => 'value', sense => -1, mode => "l" } ],
           '$modes[chanmode] for -l' );

$S2->syswrite( ':Someone!theiruser@their.host MODE #chan +shl HalfOp 123' . $CRLF );

wait_for { @messages };

( $command, $msg, $hints ) = @{ shift @messages };
$modes = $hints->{modes};

is_deeply( $modes,
           [ { type => 'bool',     sense => 1, mode => "s" },
             { type => 'occupant', sense => 1, mode => "h", flag => '%', nick => "HalfOp", nick_folded => "halfop" },
             { type => 'value',    sense => 1, mode => "l", value => "123" } ],
           '$modes[chanmode] for +shl HalfOp 123' );

$S2->syswrite( ':Someone!theiruser@their.host MODE #chan -lh+o HalfOp FullOp' . $CRLF );

wait_for { @messages };

( $command, $msg, $hints ) = @{ shift @messages };
$modes = $hints->{modes};

is_deeply( $modes,
           [ { type => 'value',    sense => -1, mode => "l" },
             { type => 'occupant', sense => -1, mode => "h", flag => '%', nick => "HalfOp", nick_folded => "halfop", },
             { type => 'occupant', sense =>  1, mode => "o", flag => '@', nick => "FullOp", nick_folded => "fullop" } ],
           '$modes[chanmode] for -lh+o HalfOp FullOp' );
