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
