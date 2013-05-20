#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008-2013 -- leonerd@leonerd.org.uk

package Net::Async::IRC;

use strict;
use warnings;

our $VERSION = '0.07';

# We need to use C3 MRO to make the ->isupport etc.. methods work properly
use mro 'c3';
use base qw( Net::Async::IRC::Protocol Protocol::IRC::Client );

use Carp;

use Socket qw( SOCK_STREAM );

=head1 NAME

C<Net::Async::IRC> - use IRC with C<IO::Async>

=head1 SYNOPSIS

 use IO::Async::Loop;
 use Net::Async::IRC;

 my $loop = IO::Async::Loop->new;

 my $irc = Net::Async::IRC->new(
    on_message_text => sub {
       my ( $self, $message, $hints ) = @_;

       print "$hints->{prefix_name} says: $hints->{text}\n";
    },
 );

 $loop->add( $irc );

 $irc->login(
    nick => "MyName",

    host => "irc.example.org",

    on_login => sub {
       $irc->send_message( "PRIVMSG", undef, "YourName", "Hello world!" );
    },
 );

 $loop->loop_forever;

=head1 DESCRIPTION

This object class implements an asynchronous IRC client, for use in programs
based on L<IO::Async>.

This documentation is very much still in a state of TODO; it is being released
now in the hope it is currently somewhat useful, with the intention of putting
more work into both the code and its documentation at some near point in the
future.

=cut

sub _init
{
   my $self = shift;
   $self->SUPER::_init( @_ );
}

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>:

=over 8

=item nick => STRING

=item user => STRING

=item realname => STRING

Connection details. See also C<connect>, C<login>.

If C<user> is not supplied, it will default to either C<$ENV{LOGNAME}> or the
current user's name as supplied by C<getpwuid()>.

If unconnected, changing these properties will set the default values to use
when logging in.

If logged in, changing the C<nick> property is equivalent to calling
C<change_nick>. Changing the other properties will not take effect until the
next login.

=back

=cut

sub configure
{
   my $self = shift;
   my %args = @_;

   for (qw( user realname )) {
      $self->{$_} = delete $args{$_} if exists $args{$_};
   }

   if( exists $args{nick} ) {
      $self->_set_nick( delete $args{nick} );
   }

   if( !defined $self->{user} ) {
      $self->{user} = $ENV{LOGNAME} || getpwuid($>);
   }

   if( !defined $self->{realname} ) {
      $self->{realname} = "Net::Async::IRC client $VERSION";
   }

   $self->SUPER::configure( %args );
}

=head1 METHODS

=cut

=head2 $irc->connect( %args )

Connects to the IRC server. This method does not perform the complete IRC
login sequence; for that see instead the C<login> method.

=over 8

=item host => STRING

Hostname of the IRC server.

=item service => STRING or NUMBER

Optional. Port number or service name of the IRC server. Defaults to 6667.

=item on_connected => CODE

Continuation to invoke once the connection has been established. Usually used
by the C<login> method to perform the actual login sequence.

 $on_connected->( $irc )

=item on_error => CODE

Continuation to invoke in the case of an error preventing the connection from
taking place.

 $on_error->( $errormsg )

=back

Any other arguments are passed into the underlying C<IO::Async::Loop>
C<connect> method.

=cut

# TODO: Most of this needs to be moved into an abstract Net::Async::Connection role
sub connect
{
   my $self = shift;
   my %args = @_;

   my $on_error = delete $args{on_error};

   $args{service} ||= "6667";

   return $self->{connect_f} ||= $self->SUPER::connect(
      %args,

      on_resolve_error => sub {
         my ( $msg ) = @_;
         chomp $msg;

         if( $args{on_resolve_error} ) {
            $args{on_resolve_error}->( $msg );
         }
         else {
            $on_error->( "Cannot resolve - $msg" );
         }
      },

      on_connect_error => sub {
         if( $args{on_connect_error} ) {
            $args{on_connect_error}->( @_ );
         }
         else {
            $on_error->( "Cannot connect" );
         }
      },
   )->on_fail( sub { undef $self->{connect_f} } );
}

=head2 $irc->login( %args )

Logs in to the IRC network, connecting first using the C<connect> method if
required. Takes the following named arguments:

=over 8

=item nick => STRING

=item user => STRING

=item realname => STRING

IRC connection details. Defaults can be set with the C<new> or C<configure>
methods.

=item pass => STRING

Server password to connect with.

=item on_login => CODE

A continuation to invoke once login is successful.

 $on_login->( $irc )

=back

Any other arguments that are passed, are forwarded to the C<connect> method if
it is required; i.e. if C<login> is invoked when not yet connected to the
server.

=cut

sub login
{
   my $self = shift;
   my %args = @_;

   my $nick     = delete $args{nick} || $self->{nick} or croak "Need a login nick";
   my $user     = delete $args{user} || $self->{user} or croak "Need a login user";
   my $realname = delete $args{realname} || $self->{realname};
   my $pass     = delete $args{pass};

   if( !defined $self->{nick} ) {
      $self->_set_nick( $nick );
   }

   my $on_login = delete $args{on_login};
   ref $on_login eq "CODE" or croak "Expected 'on_login' as a CODE reference";

   return $self->{login_f} ||= $self->connect( %args )->and_then( sub {
      $self->send_message( "PASS", undef, $pass ) if defined $pass;

      $self->send_message( "USER", undef, $user, "0", "*", $realname );

      $self->send_message( "NICK", undef, $nick );

      my $f = $self->loop->new_future;

      $self->{on_login} = sub {
         $f->done;
         goto &$on_login;
      };

      return $f;
   })->on_fail( sub { undef $self->{login_f} } );
}

=head2 $irc->change_nick( $newnick )

Requests to change the nick. If unconnected, the change happens immediately
to the stored defaults. If logged in, sends a C<NICK> command to the server,
which may suceed or fail at a later point.

=cut

sub change_nick
{
   my $self = shift;
   my ( $newnick ) = @_;

   if( !$self->is_connected ) {
      $self->_set_nick( $newnick );
   }
   else {
      $self->send_message( "NICK", undef, $newnick );
   }
}

#################################
# Methods for incremental lists #
#################################

sub build_list
{
   my $self = shift;
   my ( $list, $target, $value ) = @_;

   $target = "" if !defined $target;

   push @{ $self->{buildlist}{$target}{$list} }, $value;
}

sub build_list_from_hints
{
   my $self = shift;
   my ( $list, $hints, @keys ) = @_;

   my %value;
   @value{@keys} = @{$hints}{@keys};

   $self->build_list( $list, $hints->{target_name_folded}, \%value );
}

sub pull_list
{
   my $self = shift;
   my ( $list, $target ) = @_;

   $target = "" if !defined $target;

   return delete $self->{buildlist}{$target}{$list};
}

sub pull_list_and_invoke
{
   my $self = shift;
   my ( $list, $message, $hints ) = @_;

   my $values = $self->pull_list( $list, $hints->{target_name_folded} );

   my %hints = (
      %$hints,
      synthesized => 1,
      $list => $values,
   );

   $self->invoke( "on_message_$list", $message, \%hints ) and $hints{handled} = 1;
   $self->invoke( "on_message", $list, $message, \%hints ) and $hints{handled} = 1;

   return $hints{handled};
}

############################
# Message handling methods #
############################

sub on_message_NICK
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   if( $hints->{prefix_is_me} ) {
      $self->_set_nick( $hints->{new_nick} );
      return 1;
   }

   return 0;
}

sub on_message_RPL_WELCOME
{
   my $self = shift;
   my ( $message ) = @_;

   $self->{on_login}->( $self ) if defined $self->{on_login};
   undef $self->{on_login};

   # Don't eat it
   return 0;
}

=head2 RPL_WHOREPLY and RPL_ENDOFWHO

These messages will be collected up, per channel, and formed into a single
synthesized event called C<who>.

Its hints hash will contain an extra key, C<who>, which will be an ARRAY ref
containing the lines of the WHO reply. Each line will be a HASH reference
containing:

=over 8

=item user_ident

=item user_host

=item user_server

=item user_nick

=item user_nick_folded

=item user_flags

=back

=cut

sub on_message_RPL_ENDOFWHO
{
   my $self = shift;
   my ( $message, $hints ) = @_;
   $self->pull_list_and_invoke( "who", $message, $hints );
}

sub on_message_RPL_WHOREPLY
{
   my $self = shift;
   my ( $message, $hints ) = @_;
   $self->build_list_from_hints( "who", $hints,
      qw( user_ident user_host user_server user_nick user_nick_folded user_flags )
   );
   return 1;
}

=head2 RPL_NAMEREPLY and RPL_ENDOFNAMES

These messages will be collected up, per channel, and formed into a single
synthesized event called C<names>.

Its hints hash will contain an extra key, C<names>, which will be an ARRAY ref
containing the usernames in the channel. Each will be a HASH reference
containing:

=over 8

=item nick

=item flag

=back

=cut

sub on_message_RPL_NAMEREPLY
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   $self->build_list( "names", $hints->{target_name_folded}, $_ ) foreach @{ $hints->{names} };

   return 1;
}

sub on_message_RPL_ENDOFNAMES
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   my $names = $self->pull_list( "names", $hints->{target_name_folded} );

   my $prefixflag_re = $self->isupport( 'prefixflag_re' );
   my $re = qr/^($prefixflag_re)?(.*)$/;

   my %names;

   foreach my $name ( @$names ) {
      my ( $flag, $nick ) = $name =~ $re or next;

      $flag ||= ''; # make sure it's defined

      $names{ $self->casefold_name( $nick ) } = { nick => $nick, flag => $flag };
   }

   my %hints = (
      %$hints,
      synthesized => 1,
      names => \%names,
   );

   $self->invoke( "on_message_names", $message, \%hints ) and $hints{handled} = 1;
   $self->invoke( "on_message", "names", $message, \%hints ) and $hints{handled} = 1;

   return $hints{handled};
}

=head2 RPL_BANLIST and RPL_ENDOFBANS

These messages will be collected up, per channel, and formed into a single
synthesized event called C<bans>.

Its hints hash will contain an extra key, C<bans>, which will be an ARRAY ref
containing the ban lines. Each line will be a HASH reference containing:

=over 8

=item mask

User mask of the ban

=item by_nick

=item by_nick_folded

Nickname of the user who set the ban

=item timestamp

UNIX timestamp the ban was created

=back

=cut

sub on_message_RPL_BANLIST
{
   my $self = shift;
   my ( $message, $hints ) = @_;
   $self->build_list_from_hints( "bans", $hints,
      qw( mask by_nick by_nick_folded timestamp )
   );
   return 1;
}

sub on_message_RPL_ENDOFBANS
{
   my $self = shift;
   my ( $message, $hints ) = @_;
   $self->pull_list_and_invoke( "bans", $message, $hints );
}

=head2 RPL_MOTD, RPL_MOTDSTART and RPL_ENDOFMOTD

These messages will be collected up into a synthesized event called C<motd>.

Its hints hash will contain an extra key, C<motd>, which will be an ARRAY ref
containing the lines of the MOTD.

=cut

sub on_message_RPL_MOTD
{
   my $self = shift;
   my ( $message, $hints ) = @_;
   $self->build_list( "motd", undef, $hints->{text} );
   return 1;
}

sub on_message_RPL_MOTDSTART
{
   my $self = shift;
   my ( $message, $hints ) = @_;
   $self->build_list( "motd", undef, $hints->{text} );
   return 1;
}

sub on_message_RPL_ENDOFMOTD
{
   my $self = shift;
   my ( $message, $hints ) = @_;
   $self->pull_list_and_invoke( "motd", $message, $hints );
}

=head1 SEE ALSO

=over 4

=item *

L<http://tools.ietf.org/html/rfc2812> - Internet Relay Chat: Client Protocol

=back

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
