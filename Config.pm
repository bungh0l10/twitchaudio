package Plugins::Twitch::Config;

use strict;
use warnings;

use Slim::Utils::Prefs qw(preferences);

use constant {
    DEFAULT_CACHE_TTL             => 3600,
    DEFAULT_LIVE_CACHE_TTL        => 300,
    DEFAULT_LIVE_INITIAL_SEGMENTS => 6,
    DEFAULT_LIVE_START_BUFFER_SECONDS => 5,
    DEFAULT_LIVE_BUFFER_SECONDS   => 10,
    DEFAULT_MAX_CONCURRENT_REQUESTS => 6,
    DEFAULT_CLIENT_ID             => 'kimne78kx3ncx6brgo4mv6wki5h1ko',
};

my $prefs = preferences('plugin.twitch');

sub init {
    $prefs->init({
        cache_ttl => DEFAULT_CACHE_TTL,
        live_cache_ttl => DEFAULT_LIVE_CACHE_TTL,
        live_initial_segments => DEFAULT_LIVE_INITIAL_SEGMENTS,
        live_start_buffer_seconds => DEFAULT_LIVE_START_BUFFER_SECONDS,
        live_buffer_seconds => DEFAULT_LIVE_BUFFER_SECONDS,
        max_concurrent_requests => DEFAULT_MAX_CONCURRENT_REQUESTS,
        client_id => DEFAULT_CLIENT_ID,
    });

    return;
}

sub live_cache_ttl {
    my $ttl = $prefs->get('live_cache_ttl');

    return DEFAULT_LIVE_CACHE_TTL
        unless defined $ttl && $ttl =~ /^\d+$/ && $ttl > 0;

    return $ttl;
}

sub cache_ttl {
    my $ttl = $prefs->get('cache_ttl');

    return DEFAULT_CACHE_TTL
        unless defined $ttl && $ttl =~ /^\d+$/ && $ttl > 0;

    return $ttl;
}

sub live_initial_segments {
    my $segments = $prefs->get('live_initial_segments');

    return DEFAULT_LIVE_INITIAL_SEGMENTS
        unless defined $segments
            && $segments =~ /^\d+$/
            && $segments >= 1
            && $segments <= 10;

    return $segments;
}

sub live_buffer_seconds {
    my $seconds = $prefs->get('live_buffer_seconds');

    return DEFAULT_LIVE_BUFFER_SECONDS
        unless defined $seconds
            && $seconds =~ /^\d+(?:\.\d+)?$/
            && $seconds >= 1
            && $seconds <= 120;

    return $seconds + 0;
}

sub live_start_buffer_seconds {
    my $seconds = $prefs->get('live_start_buffer_seconds');

    return DEFAULT_LIVE_START_BUFFER_SECONDS
        unless defined $seconds
            && $seconds =~ /^\d+(?:\.\d+)?$/
            && $seconds >= 1
            && $seconds <= 120;

    return $seconds + 0;
}

sub max_concurrent_requests {
    my $requests = $prefs->get('max_concurrent_requests');

    return DEFAULT_MAX_CONCURRENT_REQUESTS
        unless defined $requests
            && $requests =~ /^\d+$/
            && $requests >= 1
            && $requests <= 12;

    return $requests + 0;
}

sub client_id {
    my $client_id = $prefs->get('client_id');

    return DEFAULT_CLIENT_ID
        unless defined $client_id
            && length $client_id
            && $client_id !~ /[[:space:][:cntrl:]]/;

    return $client_id;
}

1;
