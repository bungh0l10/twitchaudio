package Plugins::Twitch::ProtocolHandler;

use strict;
use warnings;

use parent qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Scanner::Remote ();
use Slim::Utils::Cache;
use Slim::Control::Request ();

use Plugins::Twitch::API ();

use constant {
    PLAYBACK_CACHE_TTL => 3600,
};

sub canDirectStream {
    return 1;
}

sub isAudio {
    return 1;
}

sub isRemote {
    return 1;
}

sub canSeek {
    return 0;
}

sub songBytes {
    return;
}

sub scanUrl {
    my ($class, $uri, $args) = @_;

    return unless $uri && $args && $args->{client};

    my ($channel) = $uri =~ m{^twitch://([^/]+)};
    return unless $channel;

    my $client = $args->{client};

    my $stream_url = Plugins::Twitch::API::getAudioUrl($channel);
    return unless $stream_url;

    Slim::Utils::Scanner::Remote->scanURL($stream_url, $args);

    _applyInitialMetadata($client, $channel);

    return;
}

sub _applyInitialMetadata {
    my ($client, $channel) = @_;

    return unless $client && $channel;

    my $song = $client->playingSong;
    return unless $song;

    my $cache = Slim::Utils::Cache->new;
    my $meta  = $cache->get("twitch_playback_$channel");

    return _applyCachedMetadata($client, $song, $meta)
        if $meta;

    Plugins::Twitch::API::getChannel($channel, sub {
        my ($data) = @_;

        return unless $data && $data->{user};

        my $channel_data = _buildChannelData($data->{user}, $channel);

        my $current_song = $client->playingSong;
        return unless $current_song;

        _applyMetadata($client, $current_song, $channel_data);
        _cachePlayback($channel, $channel_data);

        return;
    });

    return;
}

sub _applyCachedMetadata {
    my ($client, $song, $meta) = @_;

    return unless $song && $meta;

    _applyMetadata($client, $song, $meta);

    return;
}

sub _applyMetadata {
    my ($client, $song, $meta) = @_;

    return unless $song && $meta;

    $song->pluginData({ wmaMeta => $meta });

    Slim::Control::Request::notifyFromArray(
        $client,
        ['newmetadata']
    );

    return;
}

sub _buildChannelData {
    my ($user, $channel) = @_;

    my $stream = $user->{stream} // {};

    return {
        title  => $stream->{title} // 'Offline',
        artist => lc($user->{login} // $channel),
        cover  => $user->{profileImageURL} // '',
    };
}

sub _cachePlayback {
    my ($channel, $meta) = @_;

    return unless $channel && $meta;

    my $cache = Slim::Utils::Cache->new;

    $cache->set(
        "twitch_playback_$channel",
        $meta,
        PLAYBACK_CACHE_TTL,
    );

    return;
}

1;