#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2010-2013 -- leonerd@leonerd.org.uk

package Protocol::IRC::Client;

use strict;
use warnings;
use 5.010; # //
use base qw( Protocol::IRC );

our $VERSION = '0.02';

use Carp;

=head1 NAME

C<Protocol::IRC::Client> - IRC protocol handling for a client

=head1 DESCRIPTION

This mix-in class provides a layer of IRC message handling logic suitable for
an IRC client. It builds upon L<Protocol::IRC> to provide extra message
processing useful to IRC clients, such as handling inbound server numerics.

It provides some of the methods required by C<Protocol::IRC>:

=over 4

=item * isupport

=back

=cut

=head1 METHODS

=cut

=head2 $value = $irc->isupport( $key )

Returns an item of information from the server's C<005 ISUPPORT> lines.
Traditionally IRC servers use all-capital names for keys.

=cut

# A few hardcoded defaults from RFC 2812
my %ISUPPORT = (
   channame_re => qr/^[#&]/,
   prefixflag_re => qr/^[\@+]/,
   chanmodes_list => [qw( b k l imnpst )], # TODO: ov
);

sub isupport
{
   my $self = shift;
   my ( $field ) = @_;
   return $self->{Protocol_IRC_isupport}->{$field} // $ISUPPORT{$field};
}

sub on_message_RPL_ISUPPORT
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   my $isupport = $self->{Protocol_IRC_isupport} ||= {};

   foreach my $entry ( @{ $hints->{isupport} } ) {
      my ( $name, $value ) = $entry =~ m/^([A-Z]+)(?:=(.*))?$/;

      $value = 1 if !defined $value;

      $isupport->{$name} = $value;

      if( $name eq "PREFIX" ) {
         my $prefix = $value;

         my ( $prefix_modes, $prefix_flags ) = $prefix =~ m/^\(([a-z]+)\)(.+)$/i
            or warn( "Unable to parse PREFIX=$value" ), next;

         $isupport->{prefix_modes} = $prefix_modes;
         $isupport->{prefix_flags} = $prefix_flags;

         $isupport->{prefixflag_re} = qr/[$prefix_flags]/;

         my %prefix_map;
         $prefix_map{substr $prefix_modes, $_, 1} = substr $prefix_flags, $_, 1 for ( 0 .. length($prefix_modes) - 1 );

         $isupport->{prefix_map_m2f} = \%prefix_map;
         $isupport->{prefix_map_f2m} = { reverse %prefix_map };
      }
      elsif( $name eq "CHANMODES" ) {
         $isupport->{chanmodes_list} = [ split( m/,/, $value ) ];
      }
      elsif( $name eq "CASEMAPPING" ) {
         # TODO
         # $self->{nick_folded} = $self->casefold_name( $self->{nick} );
      }
      elsif( $name eq "CHANTYPES" ) {
         $isupport->{channame_re} = qr/^[$value]/;
      }
   }

   return 0;
}

=head2 $info = $irc->server_info( $key )

Returns an item of information from the server's C<004> line. C<$key> should
one of

=over 8

=item * host

=item * version

=item * usermodes

=item * channelmodes

=back

=cut

sub server_info
{
   my $self = shift;
   my ( $key ) = @_;

   return $self->{Protocol_IRC_server_info}{$key};
}

sub on_message_RPL_MYINFO
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   @{$self->{Protocol_IRC_server_info}}{qw( host version usermodes channelmodes )} =
      @{$hints}{qw( serverhost serverversion usermodes channelmodes )};

   return 0;
}

=head1 INTERNAL MESSAGE HANDLING

The following messages are handled internally by C<Protocol::IRC::Client>.

=cut

=head2 MODE (on channels) and 324 (RPL_CHANNELMODEIS)

These message involve channel modes. The raw list of channel modes is parsed
into an array containing one entry per affected piece of data. Each entry will
contain at least a C<type> key, indicating what sort of mode or mode change
it is:

=over 8

=item list

The mode relates to a list; bans, invites, etc..

=item value

The mode sets a value about the channel

=item bool

The mode is a simple boolean flag about the channel

=item occupant

The mode relates to a user in the channel

=back

Every mode type then provides a C<mode> key, containing the mode character
itself, and a C<sense> key which is an empty string, C<+>, or C<->.

For C<list> and C<value> types, the C<value> key gives the actual list entry
or value being set.

For C<occupant> types, a C<flag> key gives the mode converted into an occupant
flag (by the C<prefix_mode2flag> method), C<nick> and C<nick_folded> store the
user name affected.

C<boolean> types do not create any extra keys.

=cut

sub prepare_hints_channelmode
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   my ( $listmodes, $argmodes, $argsetmodes, $boolmodes ) = @{ $self->isupport( 'chanmodes_list' ) };

   my $modechars = $hints->{modechars};
   my @modeargs = @{ $hints->{modeargs} };

   my @modes; # [] -> { type => $, sense => $, mode => $, arg => $ }

   my $sense = 0;
   foreach my $modechar ( split( m//, $modechars ) ) {
      $sense =  1, next if $modechar eq "+";
      $sense = -1, next if $modechar eq "-";

      my $hasarg;

      my $mode = {
         mode  => $modechar,
         sense => $sense,
      };

      if( index( $listmodes, $modechar ) > -1 ) {
         $mode->{type} = 'list';
         $mode->{value} = shift @modeargs if ( $sense != 0 );
      }
      elsif( index( $argmodes, $modechar ) > -1 ) {
         $mode->{type} = 'value';
         $mode->{value} = shift @modeargs if ( $sense != 0 );
      }
      elsif( index( $argsetmodes, $modechar ) > -1 ) {
         $mode->{type} = 'value';
         $mode->{value} = shift @modeargs if ( $sense > 0 );
      }
      elsif( index( $boolmodes, $modechar ) > -1 ) {
         $mode->{type} = 'bool';
      }
      elsif( my $flag = $self->prefix_mode2flag( $modechar ) ) {
         $mode->{type} = 'occupant';
         $mode->{flag} = $flag;
         $mode->{nick} = shift @modeargs if ( $sense != 0 );
         $mode->{nick_folded} = $self->casefold_name( $mode->{nick} );
      }
      else {
         # TODO: Err... not recognised ... what do I do?
      }

      # TODO: Consider a per-mode event here...

      push @modes, $mode;
   }

   $hints->{modes} = \@modes;
}

sub prepare_hints_MODE
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   if( $hints->{target_type} eq "channel" ) {
      $self->prepare_hints_channelmode( $message, $hints );
   }
}

sub prepare_hints_RPL_CHANNELMODEIS
{
   my $self = shift;
   my ( $message, $hints ) = @_;

   $self->prepare_hints_channelmode( $message, $hints );
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
