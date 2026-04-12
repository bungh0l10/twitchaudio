package Plugins::Twitch::ProtocolHandler;

use strict;
use warnings;

use parent qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Log qw(logger);
use Slim::Utils::Scanner::Remote ();
use Slim::Control::Request ();
use Slim::Utils::Cache;
use Slim::Player::Client;

use Plugins::Twitch::API ();

my $log = logger('plugin.twitch');

sub scanUrl {
    my ($class, $uri, $args) = @_;

    return unless $uri && $args;

    my $channel = _extractChannel($uri);
    return unless $channel;

    my $client = _resolveClient($args->{client});
    return unless $client;

    my $stream_url = Plugins::Twitch::API::getAudioUrl($channel);
    return unless $stream_url;

    Slim::Utils::Scanner::Remote->scanURL($stream_url, $args);

    my $cache = Slim::Utils::Cache->new;
    my $cached_meta = $cache->get("twitch_meta_$channel");

    _applyMetadata($client, $channel, $cached_meta);

    return;
}

sub _applyMetadata {
    my ($client, $channel, $cached_meta) = @_;

    return unless $client;

    my $song = eval { $client->playingSong };
    return unless $song;

    if ($cached_meta) {
        _setSongMetadata($client, $song, $cached_meta);
        return;
    }

    Plugins::Twitch::API::getChannel($channel, sub {
        my ($data) = @_;
        return unless $data;

        my $meta = _buildMetadata($channel, $data);

        my $current_song = eval { $client->playingSong };
        return unless $current_song;

        _setSongMetadata($client, $current_song, $meta);

        my $cache = Slim::Utils::Cache->new;
        $cache->set("twitch_meta_$channel", $meta, 3600);

        return;
    });

    return;
}

sub _setSongMetadata {
    my ($client, $song, $meta) = @_;

    return unless $song;

    $song->pluginData({ wmaMeta => $meta });

    Slim::Control::Request::notifyFromArray(
        $client,
        ['newmetadata']
    );

    return;
}

sub _buildMetadata {
    my ($channel, $data) = @_;

    my $user   = $data->{user}   || {};
    my $stream = $user->{stream} || {};

    return {
        title  => $stream->{title} || 'Offline',
        artist => $user->{login}   || $channel,
        cover  => $user->{profileImageURL} || '',
    };
}

sub _resolveClient {
    my ($client) = @_;

    return unless $client;

    return $client if ref $client;

    return Slim::Player::Client::getClient($client);
}

sub _extractChannel {
    my ($uri) = @_;

    return unless $uri;

    if ($uri =~ m{^twitch://([^/]+)}) {
        return lc $1;
    }

    return;
}

1;