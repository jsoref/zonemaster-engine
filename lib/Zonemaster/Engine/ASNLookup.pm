package Zonemaster::Engine::ASNLookup;

use 5.014002;

use warnings;

use version; our $VERSION = version->declare( "v1.0.8" );

use Zonemaster::Engine;
use Zonemaster::Engine::Net::IP;
use Zonemaster::Engine::Nameserver;
use Zonemaster::Engine::Profile;

use IO::Socket;
use IO::Socket::INET;

our @db_servers;
our $db_style;

sub get_with_prefix {
    my ( $class, $ip ) = @_;

    if ( not @db_servers ) {
        # 
        # Backward compatibility in case asnroots is still configured in profile
        # but we prefer new model if present
        # 
        my @roots;
        if ( Zonemaster::Engine::Profile->effective->get( q{asnroots} ) ) {
            @roots = map { Zonemaster::Engine->zone( $_ ) } @{ Zonemaster::Engine::Profile->effective->get( q{asnroots} ) };
        }
        if ( scalar @roots ) {
            @db_servers = @roots;
            $db_style = q{cymru};
        }
        else {
            $db_style = Zonemaster::Engine::Profile->effective->get( q{asn_db.style} );
            my %db_servers = %{ Zonemaster::Engine::Profile->effective->get( q{asn_db.servers} ) };
            @db_servers = map { Zonemaster::Engine->zone( $_ ) } @{ $db_servers{ $db_style } };
        }
    }

    if ( not ref( $ip ) or not $ip->isa( 'Zonemaster::Engine::Net::IP' ) ) {
        $ip = Zonemaster::Engine::Net::IP->new( $ip );
    }

    if ( $db_style eq q{cymru} ) {
        return _cymru_asn_lookup($ip);
    }
    elsif ( $db_style eq q{ripe} ) {
        return _ripe_asn_lookup($ip);
    }
    else {
        if ( not $db_style ) {
            die "ASN database style is [UNDEFINED]";
        }
        else {
            die "ASN database style value [$db_style] is illegal";
        }
    }

} ## end sub get_with_prefix

sub _cymru_asn_lookup {
    my $ip = shift;
    my @asns = ();

    my $reverse = $ip->reverse_ip;
    foreach my $db_server ( @db_servers ) {
        my $domain = $db_server->name->string;
        my $pair   = {
            'in-addr.arpa.' => "origin.$domain",
            'ip6.arpa.'     => "origin6.$domain",
        };
        foreach my $root ( keys %{$pair} ) {
            if ( $reverse =~ s/$root/$pair->{$root}/ix ) {
                my $p = $db_server->query_persistent( $reverse, 'TXT' );
                my @rr;
                if ( $p ) {
                    @rr = $p->get_records( 'TXT' );
                }
                if ( $p and ( $p->rcode eq q{NXDOMAIN} or ( $p->rcode eq q{NOERROR} and not scalar @rr ) ) ) {
                    return \@asns, undef, q{}, q{EMPTY_ASN_SET};
                }
                if ( not $p or $p->rcode ne q{NOERROR} ) {
                    return \@asns, undef, q{}, q{ERROR_ASN_DATABASE};
                }

                my $prefix_length = 0;
                my @fields;
                my $str;
                foreach my $rr ( @rr ) {
                    my $_str = $rr->txtdata;
                    $_str =~ s/"([^"]+)"/$1/x;
                    my @_fields = split( /[ ][|][ ]?/x, $_str );
                    my @_asns   = split( /\s+/x,        $_fields[0] );
                    my $_prefix_length = ($_fields[1] =~ m!^.*[/](.*)!x)[0];
                    if ( $_prefix_length > $prefix_length ) {
                        $str = $_str;
                        @asns = @_asns;
                        @fields = @_fields;
                        $prefix_length = $_prefix_length;
                    }
                }
                if ( scalar @rr ) {
                    return \@asns, Zonemaster::Engine::Net::IP->new( $fields[1] ), $str, q{AS_FOUND};
                }
                else {
                    return \@asns, q{}, $str, q{ERROR_ASN_DATABASE};
                }
            }
        }
    } ## end foreach my $db_server ( @db_servers )
    return;
}

sub _ripe_asn_lookup {
    my $ip = shift;
    my @asns = ();

    foreach my $db_server ( @db_servers ) {
        my $socket = IO::Socket::INET->new( PeerAddr => $db_server->name->string, PeerPort => q{43}, Proto => q{tcp} ) or return \@asns, undef, q{}, q{ERROR_ASN_DATABASE};

        printf $socket "-F -M %s\n", $ip->short();

        my $data;
        my $str;
        my $has_answer = 0;
        while ( defined ($data = <$socket>) ) {
            $has_answer = 1;
            chop $data;
            if ( $data !~ /^%/x and $data !~ /^\s*$/x ) {
                $str = $data;
                last;
            }
        }
        $socket->close();
        if ( not $has_answer ) {
            return \@asns, undef, q{}, q{ERROR_ASN_DATABASE};
        }
        elsif ( $str )  {
            my @fields = split( /\s+/x, $str );
            @asns = ( $fields[0] );
            return \@asns, Zonemaster::Engine::Net::IP->new( $fields[1] ), $str, q{AS_FOUND};
        }
        else {
            return \@asns, undef, q{}, q{EMPTY_ASN_SET};
        }
    }
    return;
}

sub get {
    my ( $class, $ip ) = @_;

    my ( $asnref, $prefix, $raw ) = $class->get_with_prefix( $ip );

    if ( $asnref ) {
        return @{$asnref};
    }
    else {
        return;
    }
}

1;

=head1 NAME

Zonemaster::Engine::ASNLookup - do lookups of ASNs for IP addresses

=head1 SYNOPSIS

   my ($asnref, $prefix) = Zonemaster::Engine::ASNLookup->get_with_prefix( '8.8.4.4' );
   my $asnref = Zonemaster::Engine::ASNLookup->get( '192.168.0.1' );

=head1 FUNCTION

=over

=item get($addr)

Takes a string (or a L<Net::IP> object) with a single IP address, does a lookup
in a Cymru-style DNS zone and returns a list of AS numbers for the address, if
any can be found.

=item get_with_prefix($addr)

As L<get()>, except it returns a list of a reference to a list with the AS
numbers, and a Net::IP object representing the prefix of the AS.

=back

=cut
