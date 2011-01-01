#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008-2010 -- leonerd@leonerd.org.uk

package Net::Async::IRC::Message;

use strict;
use warnings;

our $VERSION = '0.04';

use Carp;
our @CARP_NOT = qw( Net::Async::IRC );

=head1 NAME

C<Net::Async::IRC::Message> - encapsulates a single IRC message

=head1 SYNOPSIS

 use Net::Async::IRC::Message;

 my $hello = Net::Async::IRC::Message->new(
    "PRIVMSG",
    undef,
    "World",
    "Hello, world!"
 );

 printf "The command is %s and the final argument is %s\n",
    $hello->command, $hello->arg( -1 );

=head1 DESCRIPTION

An object in this class represents a single IRC message, either received from
or to be sent to the server. These objects are immutable once constructed, but
provide a variety of methods to access the contained information.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $message = Net::Async::IRC::Message->new_from_line( $line )

Returns a new C<Net::Async::IRC::Message> object, constructed by parsing the
given IRC line. Most typically used to create a new object to represent a
message received from the server.

=cut

sub new_from_line
{
   my $class = shift;
   my ( $line ) = @_;

   my $prefix;
   if( $line =~ s/^:([^ ]+) +// ) {
      $prefix = $1;
   }

   my ( $mid, $final ) = split( m/ +:/, $line, 2 );
   my @args = split( m/ +/, $mid );

   push @args, $final if defined $final;

   my $command = shift @args;

   return $class->new( $command, $prefix, @args );
}

=head2 $message = Net::Async::IRC::Message->new( $command, $prefix, @args )

Returns a new C<Net::Async::IRC::Message> object, intialised from the given
components. Most typically used to create a new object to send to the server
using C<stream_to_line>.

=cut

sub new
{
   my $class = shift;
   my ( $command, $prefix, @args ) = @_;

   # IRC is case-insensitive for commands, but we'd like them in uppercase
   # to keep things simpler
   $command = uc $command;

   # Less strict checking than RFC 2812 because a lot of servers lately seem
   # to be more flexible than that.

   $command =~ m/^[A-Z]+$/ or $command =~ m/^\d\d\d$/ or
      croak "Command must be just letters or three digits";

   if( defined $prefix ) {
      $prefix =~ m/[ \t\x0d\x0a]/ and 
         croak "Prefix must not contain whitespace";
   }

   foreach ( @args[0 .. $#args-1] ) { # Not the final
      defined or croak "Argument must be defined";
      m/[ \t\x0d\x0a]/ and
         croak "Argument must not contain whitespace";
   }

   if( @args ) {
      defined $args[-1] or croak "Final argument must be defined";
      $args[-1] =~ m/[\x0d\x0a]/ and croak "Final argument must not contain a linefeed";
   }

   my $self = {
      command => $command,
      prefix  => $prefix,
      args    => \@args,
   };

   return bless $self, $class;
}

=head1 METHODS

=cut

=head2 $str = $message->STRING

=head2 $str = "$message"

Returns a string representing the message, suitable for use in a debugging
message or similar. I<Note>: This is not the same as the IRC wire form, to
send to the IRC server; for that see C<stream_to_line>.

=cut

use overload '""' => "STRING";
sub STRING
{
   my $self = shift;
   my $class = ref $self;
   return $class . "[" . 
                    ( defined $self->{prefix} ? "prefix=$self->{prefix}," : "" ) .
                    "cmd=$self->{command}," . 
                    "args=(" . join( ",", @{ $self->{args} } ) . ")]";
}

=head2 $command = $message->command

Returns the command name stored in the message object.

=cut

sub command
{
   my $self = shift;
   return $self->{command};
}

=head2 $prefix = $message->prefix

Returns the line prefix stored in the object, or the empty string if one was
not supplied.

=cut

sub prefix
{
   my $self = shift;
   return defined $self->{prefix} ? $self->{prefix} : "";
}

=head2 ( $nick, $ident, $host ) = $message->prefix_split

Splits the prefix into its nick, ident and host components. If the prefix
contains only a hostname (such as the server name), the first two components
will be returned as C<undef>.

=cut

sub prefix_split
{
   my $self = shift;

   my $prefix = $self->prefix;

   return ( $1, $2, $3 ) if $prefix =~ m/^(.*?)!(.*?)@(.*)$/;

   # $prefix doesn't split into nick!ident@host so presume host only
   return ( undef, undef, $prefix );
}

=head2 $arg = $message->arg( $index )

Returns the argument at the given index. Uses normal perl array indexing, so
negative indices work as expected.

=cut

sub arg
{
   my $self = shift;
   my ( $index ) = @_;
   return $self->{args}[$index];
}

=head2 @args = $message->args

Returns a list containing all the message arguments.

=cut

sub args
{
   my $self = shift;
   return @{$self->{args}};
}

=head2 $line = $message->stream_to_line

Returns a string suitable for sending the message to the IRC server.

=cut

sub stream_to_line
{
   my $self = shift;

   my $line = "";
   if( defined $self->{prefix} ) {
      $line .= ":$self->{prefix} ";
   }

   $line .= $self->{command};

   foreach ( @{$self->{args}} ) {
      if( m/ / or m/^:/  ) {
         $line .= " :$_";
      }
      else {
         $line .= " $_";
      }
   }

   return $line;
}

# Argument naming information

# This hash holds HASH refs giving the names of the positional arguments of
# any message. The hash keys store the argument names, and the values store
# an argument index, the string "pn" meaning prefix nick, or "$n~$m" meaning
# an index range. Endpoint can be absent.

my %ARG_NAMES = (
   INVITE  => { inviter_nick => "pn",
                invited_nick => 0,
                target_name  => 1 },
   KICK    => { kicker_nick => "pn",
                target_name => 0,
                kicked_nick => 1,
                text        => 2 },
   MODE    => { target_name => 0,
                modechars   => 1,
                modeargs    => "2.." },
   NICK    => { old_nick => "pn",
                new_nick => 0 },
   NOTICE  => { targets => 0,
                text    => 1 },
   PING    => { text => 0 },
   PONG    => { text => 0 },
   QUIT    => { text => 0 },
   PART    => { target_name => 0,
                text        => 1 },
   PRIVMSG => { targets => 0,
                text    => 1 },
   TOPIC   => { target_name => 0,
                text        => 1 },

   '004' => { serverhost    => 1,
              serverversion => 2,
              usermodes     => 3,
              channelmodes  => 4 }, # MYINFO
   '005' => { isupport => "1..-2",
              text     => -1 },     # ISUPPORT

   301 => { target_name => 1,
            text        => 2 }, # AWAY
   311 => { target_name => 1,
            ident       => 2,
            host        => 3,
            flags       => 4,
            realname    => 5 }, # WHOISUSER
   314 => { target_name => 1,
            ident       => 2,
            host        => 3,
            flags       => 4,
            realname    => 5 }, # WHOWASUSER
   317 => { target_name => 1,
            idle_time   => 2 }, # WHOISIDLE
   319 => { target_name => 1,
            channels    => '2@' }, # WHOISCHANNELS

   324 => { target_name => 1,
            modechars   => 2,
            modeargs    => "3.." }, # CHANNELMODEIS
   329 => { target_name => 1,
            timestamp   => 2 },    # CHANNELCREATED - extension not in 2812
   330 => { target_name => 1,
            whois_nick  => 2,
            login_name  => 3, },   # LOGGEDINAS - extension not in 2812
   331 => { target_name => 1 },    # NOTOPIC
   332 => { target_name => 1,
            text        => 2 },    # TOPIC
   333 => { target_name => 1,
            topic_nick  => 2,
            timestamp   => 3, },   # TOPICSETBY - extension not in 2812

   352 => { target_name => 1,
            user_ident  => 2,
            user_host   => 3,
            user_server => 4,
            user_nick   => 5,
            user_flags  => 6,
            text        => 7, # really "hopcount realname" but can't parse text yet
          }, # WHOREPLY

   353 => { target_name => 2,
            names       => '3@' }, # NAMEREPLY
   367 => { target_name => 1,
            mask        => 2,
            by_nick     => 3,
            timestamp   => 4 }, # BANLIST

   441 => { user_nick   => 1,
            target_name => 2 }, # ERR_USERNOTINCHANNEL
   443 => { user_nick   => 1,
            target_name => 2 }, # ERR_USERONCHANNEL
);

# Misc. named commands
$ARG_NAMES{$_} = { target_name => 0 } for qw(
   JOIN LIST NAMES WHO WHOIS WHOWAS
);

# Normal targeted numerics
$ARG_NAMES{$_} = { target_name => 1 } for qw(
   307 312 313 315 318 320 369 387
   328
   331 341
   346 347 348 349
   366 368
   401 402 403 404 405 406 408
   432 433 436 437
   442 444
   467 471 473 474 475 476 477 478
   482
);

# Untargeted numerics with nothing of interest
$ARG_NAMES{$_} = { } for qw(
   376
);

# Untargeted numerics with a simple text message
$ARG_NAMES{$_} = { text => 1 } for qw(
   001 002 003
   305 306
   372 375
);


# TODO: 472 ERR_UNKNOWNMODE: <char> :is unknown mode char to me for <channel>
# How to parse this one??

=head2 $names = $message->arg_names

Returns a hash giving details on how to parse named arguments for the command
given in this message.

This will be a hash whose keys give the names of the arguments, and the values
of these keys indicate how that argument is derived from the simple positional
arguments.

Normally this method is only called internally by the C<named_args> method,
but is documented here for the benefit of completeness, and in case extension
modules wish to define parsing of new message types.

Each value should be one of the following:

=over 4

=item * String literal C<pn>

The value is a string, the nickname given in the message prefix

=item * NUMBER..NUMBER

The value is an ARRAY ref, containing a list of all the numbered arguments
between the (inclusive) given limits. Either or both limits may be negative;
they will count backwards from the end.

=item * NUMBER

The value is the argument at that numeric index. May be negative to count
backwards from the end.

=item * NUMBER@

The value is the argument at that numeric index as for C<NUMBER>, except that
the result will be split on spaces and stored in an ARRAY ref.

=back

=cut

sub arg_names
{
   # Usage: Class->arg_names($command) or $self->arg_names()
   my $command;

   if( ref $_[0] ) {
      my $self = shift;
      $command = $self->{command};
   }
   else {
      my $class = shift; # ignore
      ( $command ) = @_;
      defined $command or croak 'Usage: '.__PACKAGE__.'->arg_names($command)';
   }

   return $ARG_NAMES{$command};
}

=head2 $args = $message->named_args

Parses arguments in the message according to the specification given by the
C<arg_names> method. Returns a hash of parsed arguments.

TODO: More complete documentation on the exact arg names/values per message
type.

=cut

sub named_args
{
   my $self = shift;

   my $argnames = $self->arg_names or return;

   my %named_args;
   foreach my $name ( keys %$argnames ) {
      my $argindex = $argnames->{$name};

      my $value;
      if( $argindex eq "pn" ) {
         ( $value, undef, undef ) = $self->prefix_split;
      }
      elsif( $argindex =~ m/^(-?\d+)?\.\.(-?\d+)?$/ ) {
         my ( $start, $end ) = ( $1, $2 );
         my @args = $self->args;

         defined $start or $start = 0;
         defined $end   or $end = $#args;

         $end += @args if $end < 0;

         $value = [ splice( @args, $start, $end-$start+1 ) ];
      }
      elsif( $argindex =~ m/^-?\d+$/ ) {
         $value = $self->arg( $argindex );
      }
      elsif( $argindex =~ m/^(-?\d+)\@$/ ) {
         $value = [ split ' ', $self->arg( $1 ) ];
      }
      else {
         die "Unrecognised argument specification $argindex";
      }

      $named_args{$name} = $value;
   }

   return \%named_args;
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
