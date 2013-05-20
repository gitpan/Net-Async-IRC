#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2010-2013 -- leonerd@leonerd.org.uk

package Net::Async::IRC::Protocol;

use strict;
use warnings;

our $VERSION = '0.07';

use base qw( IO::Async::Protocol::Stream Protocol::IRC );

use Carp;

use Protocol::IRC::Message;

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

         undef $self->{connect_f};
         undef $self->{login_f};
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
}

# for Protocol::IRC
sub encoder
{
   my $self = shift;
   return $self->{encoder};
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

   $self->{connect_f} = Future->new->done( $self->transport->read_handle );
   $self->{pingtimer}->start if $self->{pingtimer} and $self->get_loop;
}

sub teardown_transport
{
   my $self = shift;

   undef $self->{connect_f};
   undef $self->{login_f};
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
   return 0 unless my $connect_f = $self->{connect_f};
   return $connect_f->is_ready and !$connect_f->failure;
}

=head2 $loggedin = $irc->is_loggedin

Returns true if the full login sequence has been performed on the connection
and it is ready to use.

=cut

sub is_loggedin
{
   my $self = shift;
   return 0 unless my $login_f = $self->{login_f};
   return $login_f->is_ready and !$login_f->failure;
}

sub on_read
{
   my $self = shift;
   my ( $buffref, $eof ) = @_;

   my $pingtimer = $self->{pingtimer};

   $pingtimer->is_running ? $pingtimer->reset : $pingtimer->start;

   $self->Protocol::IRC::on_read( $$buffref );
   return 0;
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

=head1 MESSAGE HANDLING

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

sub invoke
{
   my $self = shift;
   my $retref = $self->maybe_invoke_event( @_ ) or return undef;
   return $retref->[0];
}

sub on_message_PONG
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   return 1 unless $self->{pongtimer}->is_running;

   my $lag = time - $self->{ping_send_time};

   $self->{current_lag} = $lag;
   $self->{on_pong_reply}->( $self, $lag ) if $self->{on_pong_reply};

   $self->{pongtimer}->stop;

   return 1;
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
