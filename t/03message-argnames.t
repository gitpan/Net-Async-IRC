#!/usr/bin/perl -w

use strict;

use Test::More tests => 12;
use Test::Exception;

use Net::Async::IRC::Message;

sub test_argnames
{
   my $testname = shift;
   my $line = shift;
   my %asserts = @_;

   my $msg = Net::Async::IRC::Message->new_from_line( $line );

   exists $asserts{names} and
      is_deeply( $msg->arg_names, $asserts{names}, "$testname arg_names" );

   exists $asserts{args} and
      is_deeply( $msg->named_args, $asserts{args}, "$testname named_args" );
}

test_argnames "PING",
   ":server PING 1234",
   names => { text => 0 },
   args  => { text => "1234" };

test_argnames "PRIVMSG",
   ":TheirNick!user\@server PRIVMSG YourNick :A message",
   names => { targets => 0, text => 1 },
   args  => { targets => "YourNick", text => "A message" };

test_argnames "MODE",
   ":TheirNick!user\@server MODE #somechannel +oo Some Friends",
   names => { target_name => 0, modechars => "1", modeargs => "2.." },
   args  => { target_name => "#somechannel", modechars => "+oo", modeargs => [ "Some", "Friends" ] };

test_argnames "PART",
   ":TheirNick!user\@server PART #somechannel :A leaving message",
   names => { target_name => 0, text => 1 },
   args  => { target_name => "#somechannel", text => "A leaving message" };

test_argnames "005",
   ":server 005 YourNick RED=red BLUE=blue :are supported by this server",
   names => { isupport => "1..-2", text => -1 },
   args  => { isupport => [qw( RED=red BLUE=blue )], text => "are supported by this server" };

test_argnames "324",
   ":server 324 YourNick #somechannel +ntl 300",
   names => { target_name => 1, modechars => "2", modeargs => "3.." },
   args  => { target_name => "#somechannel", modechars => "+ntl", modeargs => [ "300" ] };
