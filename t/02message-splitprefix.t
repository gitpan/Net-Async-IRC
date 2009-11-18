#!/usr/bin/perl -w

use strict;

use Test::More tests => 3;

use Net::Async::IRC::Message;

sub test_prefix
{
   my $testname = shift;
   my $line = shift;
   my ( $expect ) = @_;

   my $msg = Net::Async::IRC::Message->new_from_line( $line );

   is_deeply( [ $msg->prefix_split ], $expect, "prefix_split for $testname" );
}

test_prefix "simple",
   ':nick!user@host COMMAND',
   [ "nick", "user", "host" ];

test_prefix "fully qualified host",
   ':nick!user@fully.qualified.host COMMAND',
   [ "nick", "user", "fully.qualified.host" ];

test_prefix "servername",
   ':irc.example.com NOTICE YourNick :Hello',
   [ undef, undef, "irc.example.com" ];
