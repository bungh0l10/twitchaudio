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
my $channel_preferences_registered;

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

    unless ($channel_preferences_registered) {
        $prefs->setValidate({ validator => 'intlimit', low => 0, high => 1 },
            'use_personal_channels');
        # Also handle changes made through LMS's playerpref command.
        $prefs->setChange(sub {
            my ($pref, $value, $client) = @_;
            _initialize_personal_channels($client) if $client && $value;
        }, 'use_personal_channels');
        $channel_preferences_registered = 1;
    }

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

sub use_personal_channels {
    my ($client) = @_;
    return $client
        && ($prefs->client($client)->get('use_personal_channels') // 0) eq '1';
}

sub _initialize_personal_channels {
    my ($client) = @_;
    my $client_prefs = $prefs->client($client);
    # An existing empty list is intentional and must never be re-seeded.
    unless (defined $client_prefs->get('saved_channels')) {
        $client_prefs->set('saved_channels', [@{ saved_channels() }]);
    }
    return $client_prefs;
}

sub _channel_prefs {
    my ($client) = @_;
    return use_personal_channels($client)
        ? _initialize_personal_channels($client)
        : $prefs;
}

sub saved_channels {
    my ($client) = @_;
    my $stored = _channel_prefs($client)->get('saved_channels');
    return [] unless ref $stored eq 'ARRAY';

    my (%seen, @channels);
    for my $value (@$stored) {
        my $login = _normalize_channel_login($value);
        next unless $login && !$seen{$login}++;
        push @channels, $login;
    }

    return [sort @channels];
}

sub add_saved_channel {
    my ($value, $client) = @_;
    my $login = _normalize_channel_login($value);
    return unless $login;

    my @channels = @{ saved_channels($client) };
    return 0 if grep { $_ eq $login } @channels;

    push @channels, $login;
    _channel_prefs($client)->set('saved_channels', \@channels);

    return 1;
}

sub remove_saved_channel {
    my ($value, $client) = @_;
    my $login = _normalize_channel_login($value);
    return unless $login;

    my @stored = @{ saved_channels($client) };
    my @channels = grep { $_ ne $login } @stored;
    return 0 if @channels == @stored;

    _channel_prefs($client)->set('saved_channels', \@channels);

    return 1;
}

1;
