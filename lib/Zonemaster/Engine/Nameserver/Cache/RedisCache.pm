package Zonemaster::Engine::Nameserver::Cache::RedisCache;

use version; our $VERSION = version->declare("v1.0.0");

use 5.014002;

use strict;
use warnings;

use Class::Accessor "antlers";
use Time::HiRes qw[gettimeofday tv_interval];
use List::Util qw( min );

use Zonemaster::LDNS::Packet;
use Zonemaster::Engine::Packet;
use Zonemaster::Engine::Profile;

use base qw( Zonemaster::Engine::Nameserver::Cache );

eval( <<EOS
    use Data::MessagePack;
    use Redis;
EOS
);


if ( $@ ) {
    die "Cant' use the Redis cache. Make sure the Data::MessagePack and Redis module are installed.\n";
}

my $redis;
our $object_cache = \%Zonemaster::Engine::Nameserver::Cache::object_cache;

my $REDIS_EXPIRE = 3600; # seconds

has 'redis' => ( is => 'ro' );

my $mp = Data::MessagePack->new();

sub new {
    my $proto = shift;
    my $params = shift;
    $params->{address} = $params->{address}->ip;
    if ( exists $object_cache->{ $params->{address} } ) {
        Zonemaster::Engine->logger->add( CACHE_FETCHED => { ip => $params->{address} } );
        return $object_cache->{ $params->{address} };
    } else {
        if (! defined $redis) {
            my $redis_config = Zonemaster::Engine::Profile->effective->get( q{redis} );
            $redis = Redis->new(%{$redis_config});
        }
        $params->{redis} //= $redis;
        $params->{data} //= {};
        my $class = ref $proto || $proto;
        my $obj = Class::Accessor::new( $class, $params );

        Zonemaster::Engine->logger->add( CACHE_CREATED => { ip => $params->{address} } );
        $object_cache->{ $params->{address} } = $obj;

        return $obj;
    }
}

sub set_key {
    my ( $self, $hash, $packet ) = @_;
    my $key = "ns:" . $self->address . ":" . $hash;

    my $ttl = $REDIS_EXPIRE;

    $self->data->{$hash} = $packet;
    if ( defined $packet ) {
        my $msg = $mp->pack({
            data       => $packet->data,
            answerfrom => $packet->answerfrom,
            timestamp  => $packet->timestamp,
            querytime  => $packet->querytime,
        });
        if ( $packet->answer ) {
            my @rr = $packet->answer;
            $ttl = min( map { $_->ttl } @rr );
            $ttl = $ttl < $REDIS_EXPIRE ? $ttl : $REDIS_EXPIRE;
        }
        $self->redis->set( $key, $msg, 'EX', $ttl );
    } else {
        $self->redis->set( $key, '', 'EX', $ttl );
    }
}

sub get_key {
    my ( $self, $hash ) = @_;
    my $key = "ns:" . $self->address . ":" . $hash;

    if ( exists $self->data->{$hash} ) {
        #Zonemaster::Engine->logger->add( MEMORY_CACHE_HIT => { } );

        return (1, $self->data->{$hash});
    } elsif ($self->redis->exists($key)) {
        my $fetch_start_time = [ gettimeofday ];
        my $data = $self->redis->get( $key );
        #Zonemaster::Engine->logger->add( REDIS_CACHE_HIT => { } );
        if ( not length($data) ) {
            $self->data->{$hash} = undef;
        } else {
            my $msg = $mp->unpack( $data );
            my $packet = Zonemaster::Engine::Packet->new({ packet => Zonemaster::LDNS::Packet->new_from_wireformat($msg->{data}) });
            $packet->answerfrom( $msg->{answerfrom} );
            $packet->timestamp( $msg->{timestamp} );
            $packet->querytime( $msg->{querytime} );

            $self->data->{$hash} = $packet;
        }
        return ( 1, $self->data->{$hash} );
    }
    #Zonemaster::Engine->logger->add( CACHE_MISS => { } );
    return ( 0, undef )
}

1;
