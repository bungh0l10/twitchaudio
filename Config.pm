package Plugins::Twitch::Config;

use strict;
use warnings;

use Slim::Utils::Prefs qw(preferences);

use constant {
    DEFAULT_CACHE_TTL             => 3600,
    DEFAULT_LIVE_CACHE_TTL        => 300,
    DEFAULT_LIVE_INITIAL_SEGMENTS => 8,
    DEFAULT_LIVE_START_BUFFER_SECONDS => 8,
    DEFAULT_LIVE_BUFFER_SECONDS   => 13,
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
        client_id => DEFAULT_CLIENT_ID,
        saved_channels => [],
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

sub client_id {
    my $client_id = $prefs->get('client_id');

    return DEFAULT_CLIENT_ID
        unless defined $client_id
            && length $client_id
            && $client_id !~ /[[:space:][:cntrl:]]/;

    return $client_id;
}

sub _normalize_channel_login {
    my ($login) = @_;

    return unless defined $login;

    $login = lc $login;
    return unless $login =~ /^[a-z0-9_]{4,25}$/;

    return $login;
}

sub saved_channels {
    my $stored = $prefs->get('saved_channels');
    return [] unless ref $stored eq 'ARRAY';

    my (%seen, @channels);
    for my $value (@$stored) {
        my $login = _normalize_channel_login($value);
        next unless $login && !$seen{$login}++;
        push @channels, $login;
    }

    return \@channels;
}

sub add_saved_channel {
    my ($value) = @_;
    my $login = _normalize_channel_login($value);
    return unless $login;

    my @channels = @{ saved_channels() };
    return 0 if grep { $_ eq $login } @channels;

    push @channels, $login;
    $prefs->set('saved_channels', \@channels);

    return 1;
}

sub remove_saved_channel {
    my ($value) = @_;
    my $login = _normalize_channel_login($value);
    return unless $login;

    my @stored = @{ saved_channels() };
    my @channels = grep { $_ ne $login } @stored;
    return 0 if @channels == @stored;

    $prefs->set('saved_channels', \@channels);

    return 1;
}

1;
