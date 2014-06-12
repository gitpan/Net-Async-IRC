#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use IO::Async::Test;
use IO::Async::Loop;

use IO::Socket::INET;

use Net::Async::IRC;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop->new();
testing_loop( $loop );

# Try connect()ing to a socket we've just created
my $listensock = IO::Socket::INET->new( LocalAddr => 'localhost', Listen => 1 ) or
   die "Cannot create listensock - $!";

my $addr = $listensock->sockname;

my @errors;

my $irc = Net::Async::IRC->new(
   user => "defaultuser",
   realname => "Default Real name",

   on_message => sub { "IGNORE" },

   on_irc_error => sub {
      my $self = shift;
      my ( $err ) = @_;

      push @errors, $err;
   },
);

$loop->add( $irc );

ok( !$irc->is_connected, 'not $irc->is_connected' );

my $connect_f = $irc->connect(
   addr => [ AF_INET, SOCK_STREAM, 0, $addr ],
);

wait_for { $connect_f->is_ready };

ok( !$connect_f->failure, 'Client connects to listening socket without failure' );

ok( $irc->is_connected, '$irc->is_connected' );
ok( !$irc->is_loggedin, 'not $irc->is_loggedin' );

my $newclient = $listensock->accept;

# Now see if we can send a message
$irc->send_message( "HELLO", undef, "world" );

my $serverstream = "";

wait_for_stream { $serverstream =~ m/$CRLF/ } $newclient => $serverstream;

is( $serverstream, "HELLO world$CRLF", 'Server stream after initial client message' );

my $logged_in = 0;

my $login_f = $irc->login(
   nick => "MyNick",

   on_login => sub { $logged_in = 1 },
);

$serverstream = "";

wait_for_stream { $serverstream =~ m/$CRLF.*$CRLF/ } $newclient => $serverstream;

is( $serverstream, "USER defaultuser 0 * :Default Real name$CRLF" . 
                   "NICK MyNick$CRLF", 'Server stream after login' );

$newclient->syswrite( ":irc.example.com 001 MyNick :Welcome to IRC MyNick!defaultuser\@your.host.here$CRLF" );

wait_for { $login_f->is_ready };

ok( !$login_f->failure, 'Client logs in without failure' );

ok( $logged_in, 'Client receives logged in event' );
ok( $irc->is_connected, '$irc->is_connected' );
ok( $irc->is_loggedin, '$irc->is_loggedin' );

$newclient->syswrite( ":something invalid-here$CRLF" );

wait_for { scalar @errors };

ok( defined shift @errors, 'on_error invoked' );

done_testing;
