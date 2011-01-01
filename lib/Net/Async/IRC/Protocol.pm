#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2010 -- leonerd@leonerd.org.uk

package Net::Async::IRC::Protocol;

use strict;
use warnings;

our $VERSION = '0.04';

use base qw( IO::Async::Protocol::LineStream );

use Carp;

use Net::Async::IRC::Message;

use Encode qw( find_encoding );
use Time::HiRes qw( time );

use IO::Async::Timer::Countdown;

=head1 NAME

C<Net::Async::IRC::Protocol> - send and receive IRC messages

=head1 DESCRIPTION

This subclass of L<IO::Async::Protocol::LineStream> implements an established
IRC connection that has already completed its inital login sequence and is
ready to send and receive IRC messages. It handles base message sending and
receiving, and implements ping timers.

Objects of this type would not normally be constructed directly. For IRC
clients, see L<Net::Async::IRC> which is a subclass of it. All the events,
parameters, and methods documented below are relevant there.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $irc = Net::Async::IRC::Protocol->new( %args )

Returns a new instance of a C<Net::Async::IRC::Protocol> object. This object
represents a IRC connection to a peer. As it is a subclass of
C<IO::Async::Protocol::LineStream> its constructor takes any arguments for
that class, in addition to the parameters named below.

=cut

sub new
{
   my $class = shift;
   my %args = @_;

   my $on_closed = delete $args{on_closed};

   return $class->SUPER::new(
      %args,

      on_closed => sub {
         my ( $self ) = @_;

         my $loop = $self->get_loop;

         $self->{pingtimer}->stop;
         $self->{pongtimer}->stop;

         $on_closed->() if $on_closed;

         $self->{state} = { connected => 0, loggedin => 0 };
      },
   );
}

sub _init
{
   my $self = shift;
   $self->SUPER::_init( @_ );

   my $pingtime = 60;
   my $pongtime = 10;

   $self->{pingtimer} = IO::Async::Timer::Countdown->new(
      delay => $pingtime,

      on_expire => sub {
         my $now = time();

         $self->send_message( "PING", undef, "$now" );

         $self->{ping_send_time} = $now;

         $self->{pongtimer}->start;
      },
   );
   $self->add_child( $self->{pingtimer} );

   $self->{pongtimer} = IO::Async::Timer::Countdown->new(
      delay => $pongtime,

      on_expire => sub {
         $self->{on_ping_timeout}->( $self ) if $self->{on_ping_timeout};
      },
   );
   $self->add_child( $self->{pongtimer} );

   $self->{state} = { connected => 0, loggedin => 0 };
   $self->{isupport} = {};

   # Some initial defaults for isupport-derived values
   $self->{isupport}{channame_re} = qr/^[#&]/;
   $self->{isupport}{prefixflag_re} = qr/^[\@+]/;
   $self->{isupport}{chanmodes_list} = [qw( b k l imnpst )]; # TODO: ov
}

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>:

=over 8

=item on_message => CODE

A CODE reference to the generic message handler; see C<MESSAGE HANDLING>
below.

=item on_message_* => CODE

Any parameter whose name starts with C<on_message_> can be installed as a
handler for a specific message, in preference to the generic handler. See
C<MESSAGE HANDLING>.

=item pingtime => NUM

Amount of quiet time, in seconds, after a message is received from the peer,
until a C<PING> will be sent to check it is still alive.

=item pongtime => NUM

Timeout, in seconds, after sending a C<PING> message, to wait for a C<PONG>
response.

=item on_ping_timeout => CODE

A CODE reference to invoke if the peer fails to respond to a C<PING> message
within the given timeout.

 $on_ping_timeout->( $irc )

=item on_pong_reply => CODE

A CODE reference to invoke when the peer successfully sends a C<PONG> in
response of a C<PING> message.

 $on_pong_reply->( $irc, $lag )

Where C<$lag> is the response time in (fractional) seconds.

=item encoding => STRING

If supplied, sets an encoding to use to encode outgoing messages and decode
incoming messages.

=back

=cut

sub configure
{
   my $self = shift;
   my %args = @_;

   $self->{$_} = delete $args{$_} for grep m/^on_message/, keys %args;

   for (qw( on_ping_timeout on_pong_reply )) {
      $self->{$_} = delete $args{$_} if exists $args{$_};
   }

   if( exists $args{pingtime} ) {
      $self->{pingtimer}->configure( delay => delete $args{pingtime} );
   }

   if( exists $args{pongtime} ) {
      $self->{pongtimer}->configure( delay => delete $args{pongtime} );
   }

   if( exists $args{encoding} ) {
      my $encoding = delete $args{encoding};
      my $obj = find_encoding( $encoding );
      defined $obj or croak "Cannot handle an encoding of '$encoding'";
      $self->{encoder} = $obj;
   }

   $self->SUPER::configure( %args );
}

sub setup_transport
{
   my $self = shift;
   $self->SUPER::setup_transport( @_ );

   $self->{state}{connected} = 1;
   $self->{pingtimer}->start if $self->{pingtimer} and $self->get_loop;
}

sub teardown_transport
{
   my $self = shift;

   $self->{state} = { connected => 0, loggedin => 0 };
   $self->{pingtimer}->stop if $self->{pingtimer} and $self->get_loop;

   $self->SUPER::teardown_transport( @_ );
}

=head1 METHODS

=cut

=head2 $connect = $irc->is_connected

Returns true if a connection to the peer is established. Note that even
after a successful connection, the connection may not yet logged in to. See
also the C<is_loggedin> method.

=cut

sub is_connected
{
   my $self = shift;
   return $self->{state}{connected};
}

=head2 $loggedin = $irc->is_loggedin

Returns true if the full login sequence has been performed on the connection
and it is ready to use.

=cut

sub is_loggedin
{
   my $self = shift;
   return $self->{state}{loggedin};
}

sub on_read_line
{
   my $self = shift;
   my ( $line ) = @_;

   my $message = Net::Async::IRC::Message->new_from_line( $line );

   my $pingtimer = $self->{pingtimer};

   $pingtimer->is_running ? $pingtimer->reset : $pingtimer->start;

   # Handle these locally as a special case
   my $command = $message->command;

   if( $command eq "PING" ) {
      $self->send_message( "PONG", undef, $message->named_args->{text} );
   }
   elsif( $command eq "PONG" ) {
      return 1 unless $self->{pongtimer}->is_running;

      my $lag = time - $self->{ping_send_time};

      $self->{current_lag} = $lag;
      $self->{on_pong_reply}->( $self, $lag ) if $self->{on_pong_reply};

      $self->{pongtimer}->stop;
   }
   else {
      $self->incoming_message( $message );
   }

   return 1;
}

=head2 $irc->send_message( $message )

Sends a message to the peer from the given C<Net::Async::IRC::Message>
object.

=head2 $irc->send_message( $command, $prefix, @args )

Sends a message to the peer directly from the given arguments.

=cut

sub send_message
{
   my $self = shift;

   $self->is_connected or croak "Cannot send message without being connected";

   my $message;

   if( @_ == 1 ) {
      $message = shift;
   }
   else {
      my ( $command, $prefix, @args ) = @_;

      if( my $encoder = $self->{encoder} ) {
         my $argnames = Net::Async::IRC::Message->arg_names( $command );

         if( defined( my $i = $argnames->{text} ) ) {
            $args[$i] = $encoder->encode( $args[$i] ) if defined $args[$i];
         }
      }

      $message = Net::Async::IRC::Message->new( $command, $prefix, @args );
   }

   $self->write_line( $message->stream_to_line );
}

=head2 $irc->send_ctcp( $prefix, $target, $verb, $argstr )

Shortcut to sending a CTCP message. Sends a PRIVMSG to the given target,
containing the given verb and argument string.

=cut

sub send_ctcp
{
   my $self = shift;
   my ( $prefix, $target, $verb, $argstr ) = @_;

   $self->send_message( "PRIVMSG", undef, $target, "\001$verb $argstr\001" );
}

=head2 $irc->send_ctcprely( $prefix, $target, $verb, $argstr )

Shortcut to sending a CTCP reply. As C<send_ctcp> but using a NOTICE instead.

=cut

sub send_ctcpreply
{
   my $self = shift;
   my ( $prefix, $target, $verb, $argstr ) = @_;

   $self->send_message( "NOTICE", undef, $target, "\001$verb $argstr\001" );
}

=head1 ISUPPORT-DRIVEN UTILITIES

The following methods are controlled by the server information given in the
C<ISUPPORT> settings.

As well as the actual C<ISUPPORT> values set by the server, a number of
derived values are also calculated. Their names are all lowercase and contain
underscores, to distinguish them from the uppercase names without underscores
that the server usually sets.

=over 8

=item prefix_modes => STRING

The mode characters from C<PREFIX> (e.g. C<@%+>)

=item prefix_flags => STRING

The flag characters from C<PREFIX> (e.g. C<ohv>)

=item prefixflag_re => Regexp

A precompiled regexp that matches any of the prefix flags

=item prefix_map_m2f => HASH

A map from mode characters to flag characters

=item prefix_map_f2m => HASH

A map from flag characters to mode characters

=item chanmodes_list => ARRAY

A 4-element array containing the split portions of C<CHANMODES>;

 [ $listmodes, $argmodes, $argsetmodes, $boolmodes ]

=item casemap_1459 => BOOLEAN

True if the C<CASEMAPPING> parameter is not C<ascii>; i.e. it is some form of
RFC 1459 mapping

=item casemap_1459_strict => BOOLEAN

True if the C<CASEMAPPING> parameter is exactly C<strict-rfc1459>

=back

=cut

sub _set_isupport
{
   my $self = shift;
   my ( $isupport ) = @_;

   foreach my $name ( keys %$isupport ) {
      my $value = $isupport->{$name};

      $value = 1 if !defined $value;

      $self->{isupport}{$name} = $value;

      if( $name eq "PREFIX" ) {
         my $prefix = $value;

         my ( $prefix_modes, $prefix_flags ) = $prefix =~ m/^\(([a-z]+)\)(.+)$/;

         $self->{isupport}{prefix_modes} = $prefix_modes;
         $self->{isupport}{prefix_flags} = $prefix_flags;

         $self->{isupport}{prefixflag_re} = qr/[$prefix_flags]/;

         my %prefix_map;
         $prefix_map{substr $prefix_modes, $_, 1} = substr $prefix_flags, $_, 1 for ( 0 .. length($prefix_modes) - 1 );

         $self->{isupport}{prefix_map_m2f} = \%prefix_map;
         $self->{isupport}{prefix_map_f2m} = { reverse %prefix_map };
      }
      elsif( $name eq "CHANMODES" ) {
         $self->{isupport}{chanmodes_list} = [ split( m/,/, $value ) ];
      }
      elsif( $name eq "CASEMAPPING" ) {
         $self->{isupport}{casemap_1459} = ( lc $value ne "ascii" ); # RFC 1459 unless we're told not
         $self->{isupport}{casemap_1459_strict} = ( lc $value eq "strict-rfc1459" );

         $self->{nick_folded} = $self->casefold_name( $self->{nick} );
      }
      elsif( $name eq "CHANTYPES" ) {
         $self->{isupport}{channame_re} = qr/^[$value]/;
      }
   }
}

=head2 $value = $irc->isupport( $key )

Returns an item of information from the server's C<005 ISUPPORT> lines.
Traditionally IRC servers use all-capital names for keys.

=cut

sub isupport
{
   my $self = shift;
   my ( $flag ) = @_;

   return exists $self->{isupport}->{$flag} ? 
                 $self->{isupport}->{$flag} : undef;
}

=head2 $cmp = $irc->cmp_prefix_flags( $lhs, $rhs )

Compares two channel occupant prefix flags, and returns a signed integer to
indicate which of them has higher priviledge, according to the server's
ISUPPORT declaration. Suitable for use in a C<sort()> function or similar.

=cut

sub cmp_prefix_flags
{
   my $self = shift;
   my ( $lhs, $rhs ) = @_;

   return undef unless defined $lhs and defined $rhs;

   # As a special case, compare emptystring as being lower than voice
   return 0 if $lhs eq "" and $rhs eq "";
   return 1 if $rhs eq "";
   return -1 if $lhs eq "";

   my $PREFIX_FLAGS = $self->isupport( "prefix_flags" );

   ( my $lhs_index = index $PREFIX_FLAGS, $lhs ) > -1 or return undef;
   ( my $rhs_index = index $PREFIX_FLAGS, $rhs ) > -1 or return undef;

   # IRC puts these in greatest-first, so we need to swap the ordering here
   return $rhs_index <=> $lhs_index;
}

=head2 $cmp = $irc->cmp_prefix_modes( $lhs, $rhs )

Similar to C<cmp_prefix_flags>, but compares channel occupant C<MODE> command
flags.

=cut

sub cmp_prefix_modes
{
   my $self = shift;
   my ( $lhs, $rhs ) = @_;

   return undef unless defined $lhs and defined $rhs;

   my $PREFIX_MODES = $self->isupport( "prefix_modes" );

   ( my $lhs_index = index $PREFIX_MODES, $lhs ) > -1 or return undef;
   ( my $rhs_index = index $PREFIX_MODES, $rhs ) > -1 or return undef;

   # IRC puts these in greatest-first, so we need to swap the ordering here
   return $rhs_index <=> $lhs_index;
}

=head2 $flag = $irc->prefix_mode2flag( $mode )

Converts a channel occupant C<MODE> flag (such as C<o>) into a name prefix
flag (such as C<@>).

=cut

sub prefix_mode2flag
{
   my $self = shift;
   my ( $mode ) = @_;

   return $self->{isupport}{prefix_map_m2f}{$mode};
}

=head2 $mode = $irc->prefix_flag2mode( $flag )

The inverse of C<prefix_mode2flag>.

=cut

sub prefix_flag2mode
{
   my $self = shift;
   my ( $flag ) = @_;

   return $self->{isupport}{prefix_map_f2m}{$flag};
}

=head2 $name_folded = $irc->casefold_name( $name )

Returns the C<$name>, folded in case according to the server's C<CASEMAPPING>
C<ISUPPORT>. Such a folded name will compare using C<eq> according to whether the
server would consider it the same name.

Useful for use in hash keys or similar.

=cut

sub casefold_name
{
   my $self = shift;
   my ( $nick ) = @_;

   return undef unless defined $nick;

   # Squash the 'capital' [\] into lowercase {|}
   $nick =~ tr/[\\]/{|}/ if $self->{isupport}{casemap_1459};

   # Most RFC 1459 implementations also squash ^ to ~, even though the RFC
   # didn't mention it
   $nick =~ tr/^/~/ unless $self->{isupport}{casemap_1459_strict};

   return lc $nick;
}

=head2 $classification = $irc->classify_name( $name )

Returns C<channel> if the given name matches the pattern of names allowed for
channels according to the server's C<CHANTYPES> C<ISUPPORT>. Returns C<user>
if not.

=cut

sub classify_name
{
   my $self = shift;
   my ( $name ) = @_;

   return "channel" if $name =~ $self->{isupport}{channame_re};
   return "user"; # TODO: Perhaps we can be a bit stricter - only check for valid nick chars?
}

=head2 $nick = $irc->nick

Returns the current nick in use by the connection.

=cut

sub _set_nick
{
   my $self = shift;
   ( $self->{nick} ) = @_;
   $self->{nick_folded} = $self->casefold_name( $self->{nick} );
}

sub nick
{
   my $self = shift;
   return $self->{nick};
}

=head2 $nick_folded = $irc->nick_folded

Returns the current nick in use by the connection, folded by C<casefold_name>
for convenience.

=cut

sub nick_folded
{
   my $self = shift;
   return $self->{nick_folded};
}

=head2 $me = $irc->is_nick_me( $nick )

Returns true if the given nick refers to that in use by the connection.

=cut

sub is_nick_me
{
   my $self = shift;
   my ( $nick ) = @_;

   return $self->casefold_name( $nick ) eq $self->{nick_folded};
}

=head1 MESSAGE HANDLING

Every incoming message causes a sequence of message handling to occur. First,
the message is parsed, and a hash of data about it is created; this is called
the hints hash. The message and this hash are then passed down a sequence of
potential handlers. 

Each handler indicates by return value, whether it considers the message to
have been handled. Processing of the message is not interrupted the first time
a handler declares to have handled a message. Instead, the hints hash is marked
to say it has been handled. Later handlers can still inspect the message or its
hints, using this information to decide if they wish to take further action.

A message with a command of C<COMMAND> will try handlers in following places:

=over 4

=item 1.

A CODE ref in a parameter called C<on_message_COMMAND>

 $on_message_COMMAND->( $irc, $message, \%hints )

=item 2.

A method called C<on_message_COMMAND>

 $irc->on_message_COMMAND( $message, \%hints )

=item 3.

A CODE ref in a parameter called C<on_message>

 $on_message->( $irc, 'COMMAND', $message, \%hints )

=item 4.

A method called C<on_message>

 $irc->on_message( 'COMMAND', $message, \%hints )

=back

Certain commands are handled internally by methods on the base
C<Net::Async::IRC::Protocol> class itself. These may cause other hints hash
keys to be created, or to invoke other handler methods. These are documented
below.

=cut

=head2 Message Hints

The following keys will be present in any message hint hash:

=over 8

=item handled => BOOL

Initially false. Will be set to true the first time a handler returns a true
value.

=item prefix_nick => STRING

=item prefix_user => STRING

=item prefix_host => STRING

Values split from the message prefix; see the C<Net::Async::IRC::Message>
C<prefix_split> method.

=item prefix_name => STRING

Usually the prefix nick, or the hostname in case the nick isn't defined
(usually on server messages).

=item prefix_is_me => BOOL

True if the nick mentioned in the prefix refers to this connection.

=back

Added to this set, will be all the values returned by the message's
C<named_args> method. Some of these values may cause yet more values to be
generated.

If the message type defines a C<target_name>:

=over 8

=item * target_type => STRING

Either C<channel> or C<user>, as returned by C<classify_name>.

=item * target_is_me => BOOL

True if the target name is a user and refers to this connection.

=back

Finally, any key whose name ends in C<_nick> or C<_name> will have a
corresponding key added with C<_folded> suffixed on its name, containing the
value casefolded using C<casefold_name>. This is for the convenience of string
comparisons, hash keys, etc..

=cut

sub _invoke
{
   my $self = shift;
   my $retref = $self->maybe_invoke_event( @_ ) or return undef;
   return $retref->[0];
}

sub incoming_message
{
   my $self = shift;
   my ( $message ) = @_;

   my $command = $message->command;

   my ( $prefix_nick, $prefix_user, $prefix_host ) = $message->prefix_split;

   my $hints = {
      handled => 0,

      prefix_nick  => $prefix_nick,
      prefix_user  => $prefix_user,
      prefix_host  => $prefix_host,
      # Most of the time this will be "nick", except for special messages from the server
      prefix_name  => defined $prefix_nick ? $prefix_nick : $prefix_host,
      prefix_is_me => defined $prefix_nick && $self->is_nick_me( $prefix_nick ),
   };

   if( my $named_args = $message->named_args ) {
      $hints->{$_} = $named_args->{$_} for keys %$named_args;
   }

   if( defined $hints->{text} and $self->{encoder} ) {
      $hints->{text} = $self->{encoder}->decode( $hints->{text} );
   }

   if( defined( my $target_name = $hints->{target_name} ) ) {
      $hints->{target_is_me} = $self->is_nick_me( $target_name );

      my $target_type = $self->classify_name( $target_name );
      $hints->{target_type} = $target_type;
   }

   my $prepare_method = "prepare_hints_$command";
   $self->$prepare_method( $message, $hints ) if $self->can( $prepare_method );

   foreach my $k ( grep { m/_nick$/ or m/_name$/ } keys %$hints ) {
      $hints->{"${k}_folded"} = $self->casefold_name( $hints->{$k} );
   }

   $self->_invoke( "on_message_$command", $message, $hints ) and $hints->{handled} = 1;
   $self->_invoke( "on_message", $command, $message, $hints ) and $hints->{handled} = 1;
}

sub on_message_NOTICE
{
   my $self = shift;
   my ( $message, $hints ) = @_;
   return $self->_on_message_text( $message, $hints, 1 );
}

sub on_message_PRIVMSG
{
   my $self = shift;
   my ( $message, $hints ) = @_;
   return $self->_on_message_text( $message, $hints, 0 );
}

=head2 NOTICE and PRIVMSG

Because C<NOTICE> and C<PRIVMSG> are so similar, they are handled together by
synthesized events called C<text>, C<ctcp> and C<ctcpreply>. Depending on the
contents of the text, and whether it was supplied in a C<PRIVMSG> or a
C<NOTICE>, one of these three events will be created. 

In all cases, the hints hash will contain a C<is_notice> key being true or
false, depending on whether the original messages was a C<NOTICE> or a
C<PRIVMSG>, a C<target_name> key containing the message target name, a
case-folded version of the name in a C<target_name_folded> key, and a
classification of the target type in a C<target_type> key.

For the C<user> target type, it will contain a boolean in C<target_is_me> to
indicate if the target of the message is the user represented by this
connection.

For the C<channel> target type, it will contain a C<restriction> key
containing the channel message restriction, if present.

For normal C<text> messages, it will contain a key C<text> containing the
actual message text.

For either CTCP message type, it will contain keys C<ctcp_verb> and
C<ctcp_args> with the parsed message. The C<ctcp_verb> will contain the first
space-separated token, and C<ctcp_args> will be a string containing the rest
of the line, otherwise unmodified. This type of message is also subject to a
special stage of handler dispatch, involving the CTCP verb string. For
messages with C<VERB> as the verb, the following are tried. C<CTCP> may stand
for either C<ctcp> or C<ctcpreply>.

=over 4

=item 1.

A CODE ref in a parameter called C<on_message_CTCP_VERB>

 $on_message_CTCP_VERB->( $irc, $message, \%hints )

=item 2.

A method called C<on_message_CTCP_VERB>

 $irc->on_message_CTCP_VERB( $message, \%hints )

=item 3.

A CODE ref in a parameter called C<on_message_CTCP>

 $on_message_CTCP->( $irc, 'VERB', $message, \%hints )

=item 4.

A method called C<on_message_CTCP>

 $irc->on_message_CTCP( 'VERB', $message, \%hintss )

=item 5.

A CODE ref in a parameter called C<on_message>

 $on_message->( $irc, 'CTCP VERB', $message, \%hints )

=item 6.

A method called C<on_message>

 $irc->on_message( 'CTCP VERB', $message, \%hints )

=back

=cut

sub _on_message_text
{
   my $self = shift;
   my ( $message, $hints, $is_notice ) = @_;

   my %hints = (
      %$hints,
      synthesized => 1,
      is_notice => $is_notice,
   );

   # TODO: In client->server messages this might be a comma-separated list
   my $target = delete $hints{targets};

   my $prefixflag_re = $self->isupport( 'prefixflag_re' );

   my $restriction = "";
   while( $target =~ m/^$prefixflag_re/ ) {
      $restriction .= substr( $target, 0, 1, "" );
   }

   $hints{target_name} = $target;
   $hints{target_name_folded} = $self->casefold_name( $target );

   my $type = $hints{target_type} = $self->classify_name( $target );

   if( $type eq "channel" ) {
      $hints{restriction} = $restriction;
      $hints{target_is_me} = '';
   }
   elsif( $type eq "user" ) {
      # TODO: user messages probably can't have restrictions. What to do
      # if we got one?
      $hints{target_is_me} = $self->is_nick_me( $target );
   }

   my $text = $hints->{text};

   if( $text =~ m/^\x01(.*)\x01$/ ) {
      ( my $verb, $text ) = split( m/ /, $1, 2 );
      $hints{ctcp_verb} = $verb;
      $hints{ctcp_args} = $text;

      my $ctcptype = $is_notice ? "ctcpreply" : "ctcp";

      $self->_invoke( "on_message_${ctcptype}_$verb", $message, \%hints ) and $hints{handled} = 1;
      $self->_invoke( "on_message_${ctcptype}", $verb, $message, \%hints ) and $hints{handled} = 1;
      $self->_invoke( "on_message", "$ctcptype $verb", $message, \%hints ) and $hints{handled} = 1;
   }
   else {
      $hints{text} = $text;

      $self->_invoke( "on_message_text", $message, \%hints ) and $hints{handled} = 1;
      $self->_invoke( "on_message", "text", $message, \%hints ) and $hints{handled} = 1;
   }

   return $hints{handled};
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
