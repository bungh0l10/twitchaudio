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
        oauth_client_id => '',
        helix_metadata => 1,
        oauth_account => '',
        show_local_channels => 1,
        show_followed => 1,
        show_followed_live => 1,
        saved_channels => [],
    });

    unless ($channel_preferences_registered) {
        $prefs->setValidate(sub { !defined $_[1] || $_[1] eq '' || $_[1] =~ /^[a-zA-Z0-9]{10,100}$/ }, 'oauth_client_id');
        $prefs->setChange(sub {
            Plugins::Twitch::OAuth::disconnect_all()
                if Plugins::Twitch::OAuth->can('disconnect_all');
        }, 'oauth_client_id');
        $prefs->setValidate({ validator => 'intlimit', low => 0, high => 1 }, 'helix_metadata');
        $prefs->setValidate(sub { defined $_[1] && $_[1] =~ /^(?:inherit|none|default|a[0-9]+|)$/ }, 'oauth_account');
        $prefs->setValidate(sub { defined $_[1] && $_[1] =~ /^(?:inherit|graphql|helix)$/ }, 'metadata_source');
        $prefs->setValidate(sub { defined $_[1] && $_[1] =~ /^(?:inherit|0|1)$/ },
            qw(show_local_channels show_followed show_followed_live));
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

sub oauth_client_id {
    my $id = $prefs->get('oauth_client_id') || '';
    return $id =~ /^[a-zA-Z0-9]{10,100}$/ ? $id : '';
}

sub account_id {
    my ($client) = @_;
    my $id = $client ? $prefs->client($client)->get('oauth_account') : undef;
    $id = $prefs->get('oauth_account') unless defined $id && $id ne 'inherit';
    return $id && $id ne 'inherit' ? $id : 'none';
}

sub helix_metadata {
    my ($client) = @_;
    my $source = $client ? $prefs->client($client)->get('metadata_source') : undef;
    return $source eq 'helix' ? 1 : 0 if $source && $source ne 'inherit';
    return $prefs->get('helix_metadata') ? 1 : 0;
}

sub menu_visible {
    my ($key, $client) = @_;
    my $value = $client ? $prefs->client($client)->get($key) : undef;
    $value = $prefs->get($key) unless defined $value && $value ne 'inherit';
    return defined $value && "$value" eq '1' ? 1 : 0;
}

sub initialize_player {
    my ($client) = @_;
    if ($client && $client->can('name')) {
        my $cp = $prefs->client($client);
        $cp->set('twitch_player_name', $client->name)
            if ($cp->get('twitch_player_name') || '') ne $client->name;
    }
    $prefs->client($client)->init({
        oauth_account => 'inherit', metadata_source => 'inherit',
        show_local_channels => 'inherit', show_followed => 'inherit', show_followed_live => 'inherit',
        use_personal_channels => 0,
    }) if $client;
}

sub remove_account_references {
    my ($id) = @_;
    $prefs->set('oauth_account', 'none') if ($prefs->get('oauth_account') || '') eq $id;
    # Also clear assignments for offline players. Only this plugin's stable
    # account-ID field is rewritten; no player migration is required for it.
    for my $cp ($prefs->allClients) {
        $cp->set('oauth_account', 'none') if ($cp->get('oauth_account') || '') eq $id;
    }
}

sub account_players {
    my ($id) = @_;
    my @names;
    for my $cp ($prefs->allClients) {
        my $player = $cp->{clientid};
        my $selected = $cp->get('oauth_account') || 'inherit';
        $selected = $prefs->get('oauth_account') if $selected eq 'inherit';
        push @names, $cp->get('twitch_player_name') || $player if ($selected || '') eq $id;
    }
    return [sort @names];
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
