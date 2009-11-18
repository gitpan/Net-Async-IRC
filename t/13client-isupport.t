#!/usr/bin/perl -w

use strict;

use Test::More tests => 27;
use IO::Async::Test;
use IO::Async::Loop;
use IO::Async::Stream;

use Net::Async::IRC;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop->new();
testing_loop( $loop );

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

my $irc = Net::Async::IRC->new(
   handle => $S1,
   on_message => sub { "IGNORE" },
);

ok( defined $irc, 'defined $irc' );

$loop->add( $irc );

$irc->login(
   nick => "Nick",
   user => "user",
   realname => "realname",

   on_login => sub { "IGNORE" },
);

my $serverstream = "";

wait_for_stream { $serverstream =~ m/$CRLF.*$CRLF/ } $S2 => $serverstream;

$S2->syswrite( ':irc.example.com 001 YourNameHere :Welcome to IRC YourNameHere!me@your.host' . $CRLF );

$S2->syswrite( ':irc.example.com 005 YourNameHere NAMESX MAXCHANNELS=10 NICKLEN=30 PREFIX=(ohv)@%+ CASEMAPPING=rfc1459 CHANMODES=beI,k,l,imnpsta CHANTYPES=#& :are supported by this server' . $CRLF );

wait_for { defined $irc->isupport( "NAMESX" ) };

is( $irc->isupport( "NAMESX" ), 1, 'ISUPPORT NAMESX is true' );

is( $irc->isupport( "MAXCHANNELS" ), "10", 'ISUPPORT MAXCHANNELS is 10' );

is( $irc->isupport( "PREFIX" ), "(ohv)\@\%+", 'ISUPPORT PREFIX is (ohv)@%+' );

is( $irc->isupport( "CHANMODES" ), "beI,k,l,imnpsta", 'ISUPPORT CHANMODES is beI,k,l,imnpsta' );

is( $irc->isupport( "CHANTYPES" ), "#&", 'ISUPPORT CHANTYPES is #&' );

# Now the generated ones from PREFIX
is( $irc->isupport( "PREFIX_MODES" ), "ohv", 'ISUPPORT PREFIX_MODES is ohv' );
is( $irc->isupport( "PREFIX_FLAGS" ), "\@\%+", 'ISUPPORT PREFIX_FLAGS is @%+' );

is( $irc->prefix_mode2flag( "o" ), "\@", 'prefix_mode2flag o -> @' );
is( $irc->prefix_flag2mode( "\@" ), "o", 'prefix_flag2mode @ -> o' );

is( $irc->cmp_prefix_flags( "\@", "\%" ),  1,    'cmp_prefix_flags @ % -> 1' );
is( $irc->cmp_prefix_flags( "\%", "\@" ), -1,    'cmp_prefix_flags % @ -> -1' );
is( $irc->cmp_prefix_flags( "\%", "\%" ),  0,    'cmp_prefix_flags % % -> 0' );
is( $irc->cmp_prefix_flags( "\%", "\$" ), undef, 'cmp_prefix_flags % $ -> undef' );

is( $irc->cmp_prefix_modes( "o", "h" ),  1,    'cmp_prefix_modes o h -> 1' );
is( $irc->cmp_prefix_modes( "h", "o" ), -1,    'cmp_prefix_modes h o -> -1' );
is( $irc->cmp_prefix_modes( "h", "h" ),  0,    'cmp_prefix_modes h h -> 0' );
is( $irc->cmp_prefix_modes( "h", "b" ), undef, 'cmp_prefix_modes h b -> undef' );

is( $irc->casefold_name( "NAME" ),      "name",      'casefold_name NAME' );
is( $irc->casefold_name( "FOO[AWAY]" ), "foo{away}", 'casefold_name FOO[AWAY]' );
is( $irc->casefold_name( "user^name" ), "user~name", 'casefold_name user^name' );

is( $irc->classify_name( "UserName"   ), "user",    'classify_name UserName' );
is( $irc->classify_name( "#somewhere" ), "channel", 'classify_name #somewhere' );

## CHEATING
$S2->syswrite( ':irc.example.com 005 YourNameHere CASEMAPPING=strict-rfc1459 :are supported by this server' . $CRLF );
wait_for { $irc->isupport( "CASEMAPPING" ) eq "strict-rfc1459" };
## END CHEATING

is( $irc->casefold_name( "FOO[AWAY]" ), "foo{away}", 'casefold_name FOO[AWAY] under strict' );
is( $irc->casefold_name( "user^name" ), "user^name", 'casefold_name user^name under strict' );

## CHEATING
$S2->syswrite( ':irc.example.com 005 YourNameHere CASEMAPPING=ascii :are supported by this server' . $CRLF );
wait_for { $irc->isupport( "CASEMAPPING" ) eq "ascii" };
## END CHEATING

is( $irc->casefold_name( "FOO[AWAY]" ), "foo[away]", 'casefold_name FOO[AWAY] under ascii' );

# Now the generated ones from CHANMODES
is_deeply( $irc->isupport( "CHANMODES_LIST" ), [qw( beI k l imnpsta )], 'ISUPPORT CHANMODES_LIST is [qw( beI k l imnpsta )]' );
