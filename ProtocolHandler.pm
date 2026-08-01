package Plugins::Twitch::ProtocolHandler;

use strict;
use warnings;

use parent qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Scanner::Remote ();
use Slim::Utils::Cache;
use Slim::Control::Request ();
use Time::HiRes qw(time);

use Plugins::Twitch::API ();
use Plugins::Twitch::Config ();
use Plugins::Twitch::HLSStream ();

my $log = logger('plugin.twitch');

use constant METADATA_RETRY_DELAY => 30;

sub _metadata_refresh_allowed {
    my ($song) = @_;
    return unless $song;
    return if $song->pluginData('twitchMetadataRefreshRequested');

    my $refresh_after = $song->pluginData('twitchMetadataRefreshAfter') || 0;
    return time() >= $refresh_after ? 1 : 0;
}

sub _begin_metadata_refresh {
    my ($song) = @_;
    return unless _metadata_refresh_allowed($song);

    $song->pluginData('twitchMetadataRefreshRequested', 1);
    $song->pluginData(
        'twitchMetadataRefreshAfter',
        time() + METADATA_RETRY_DELAY,
    );
    return 1;
}

sub _finish_metadata_refresh {
    my ($song, $success, $success_ttl) = @_;
    return unless $song;

    $song->pluginData('twitchMetadataRefreshRequested', 0);
    $song->pluginData(
        'twitchMetadataRefreshAfter',
        time() + ($success ? $success_ttl : METADATA_RETRY_DELAY),
    );
    return;
}

sub _apply_song_metadata {
    my ($client, $song, $meta) = @_;
    return unless $client && $song && ref $meta eq 'HASH';

    my $current = $song->pluginData('wmaMeta');
    if (ref $current eq 'HASH') {
        my $changed = 0;
        for my $field (qw(title artist cover)) {
            my $old = defined $current->{$field} ? $current->{$field} : '';
            my $new = defined $meta->{$field} ? $meta->{$field} : '';
            $changed = 1 if $old ne $new;
        }
        return unless $changed;
    }

    $song->pluginData('wmaMeta', $meta);
    Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
    return 1;
}

sub _set_hls_args {
    my ($args) = @_;

    @$args{qw(parser contentType streamformat noVideo)} = (
        'Plugins::Twitch::HLSStream',
        'audio/aac',
        'aac',
        1,
    );

    return;
}

sub _native_hls_url {
    my ($url) = @_;
    $url =~ s{^https:}{twitchhls:};
    $url =~ s{^http:}{twitchhls:};
    return $url;
}

sub _song_for_media_id {
    my ($client, $id) = @_;
    return unless $client;
    if ($client->can('currentSongForUrl')) {
        my $song = $client->currentSongForUrl("twitch:$id");
        return $song if $song;
    }

    my $song = $client->playingSong or return;
    for my $method (qw(track currentTrack)) {
        next unless $song->can($method);
        my $track = $song->$method or next;
        return $song if $track->can('url')
            && ($track->url || '') =~ /^twitch:\Q$id\E(?:[|?#]|$)/;
    }
    return;
}

sub canDirectStream { 0 }
sub isAudio          { 1 }
sub isRemote         { 1 }
sub canSeek          { 0 }
sub songBytes        { 0 }

sub getMetadataFor {
    my ($class, $client, $url, $force, $song) = @_;
    my $meta = Plugins::Twitch::HLSStream->getMetadataFor(
        $client,
        $url,
        $force,
        $song,
    );

    if ($client && $url =~ /^twitch:(live|vod):([^|?#]+)/)
    {
        my ($type, $value) = ($1, $2);
        my $song = _song_for_media_id($client, "$type:$value");
        if ($song && ($type eq 'live'
            || (!$meta->{artist} && !$meta->{cover})))
        {
            _applyInitialMetadata($client, "$type:$value", $song);
        }
    }

    return $meta;
}

# HTTPS::currentTrackHandler intentionally keeps a subclass as the handler.
# That is correct for ordinary HTTPS redirects, but wrong after scanUrl()
# changes twitch: into twitchhls:.  Without this override LMS opens the
# first twitchhls URL with the inherited HTTPS handler and waits for its
# socket timeout before a second Play attempt uses HLSStream.
sub currentTrackHandler {
    my ($class, $song, $track) = @_;
    return Slim::Player::ProtocolHandlers->handlerForURL($track->url);
}

sub scanUrl {
    my ($class, $uri, $args) = @_;

    return unless $uri && $args && $args->{client};

    my $client = $args->{client};

    if ($uri =~ m{^twitch:live:([^:]+)$}) {
        my $channel = $1;

        _scan_stream(
            $args,
            $client,
            "live:$channel",
            sub {
                my ($callback) = @_;
                Plugins::Twitch::API::getAudioUrl($channel, $callback);
            },
        );

        return;
    }

    if ($uri =~ m{^twitch:vod:(\d+)$}) {
        my $vod_id = $1;

        _scan_stream(
            $args,
            $client,
            "vod:$vod_id",
            sub {
                my ($callback) = @_;
                Plugins::Twitch::API::getVodAudioUrl($vod_id, $callback);
            },
        );

        return;
    }

    return;
}

sub _scan_stream {
    my ($args, $client, $media_id, $fetch_url) = @_;

    my $media_type = $media_id =~ /^vod:/ ? 'vod' : 'live';
    my $song = $args->{song} || $client->playingSong;
    $song->pluginData('twitchMediaType', $media_type) if $song;

    $fetch_url->(sub {
        my ($stream_url) = @_;
        return unless $stream_url;

        my $stream_type = uc($media_type);
        # $log->debug("TWITCH $stream_type STREAM URL: $stream_url");

        my $native_url = _native_hls_url($stream_url);
        my $cache = Slim::Utils::Cache->new;
        for my $url ($stream_url, $native_url) {
            $cache->set(
                "twitch:media-for-url:$url",
                $media_id,
                Plugins::Twitch::Config::cache_ttl(),
            );
        }
        _set_hls_args($args);
        Slim::Utils::Scanner::Remote->scanURL($native_url, $args);
        _applyInitialMetadata($client, $media_id, $song);

        return;
    });

    return;
}

sub _applyInitialMetadata {
    my ($client, $id, $song) = @_;

    return unless $client && $id;

    $song ||= _song_for_media_id($client, $id);
    return unless $song;
    my $cache = Slim::Utils::Cache->new;

    if ($id =~ /^vod:(\d+)$/) {
        my $vod_id = $1;

        my $meta = $cache->get("twitch:vod:$vod_id");

        if ($meta) {
            _apply_song_metadata($client, $song, $meta);
            return;
        }

        return unless _begin_metadata_refresh($song);

        Plugins::Twitch::API::getVodMeta($vod_id, sub {
            my ($vod) = @_;

            _finish_metadata_refresh(
                $song,
                $vod ? 1 : 0,
                Plugins::Twitch::Config::cache_ttl(),
            );
            return unless $vod;

            my $meta = {
                title  => $vod->{title} // 'VOD',
                artist => $vod->{artist},
                cover  => $vod->{thumbnail},
            };

            _apply_song_metadata($client, $song, $meta);

            $cache->set(
                "twitch:vod:$vod_id",
                $meta,
                Plugins::Twitch::Config::cache_ttl(),
            );
        });

        return;
    }

    my ($type, $channel) = split /:/, $id, 2;
    $channel ||= $id;

    my $current_meta = $song->pluginData('wmaMeta');
    unless (ref $current_meta eq 'HASH'
        && ($current_meta->{title}
            || $current_meta->{artist}
            || $current_meta->{cover}))
    {
        my $meta = $cache->get("twitch:live:$channel");
        _apply_song_metadata($client, $song, $meta) if $meta;
    }

    return unless _begin_metadata_refresh($song);

    Plugins::Twitch::API::getChannel($channel, sub {
        my ($data) = @_;

        my $success = $data && $data->{user} ? 1 : 0;
        _finish_metadata_refresh(
            $song,
            $success,
            Plugins::Twitch::Config::live_cache_ttl(),
        );
        return unless $data && $data->{user};

        my $u = $data->{user};
        my $title = $u->{stream}->{title}
            // cstring($client, 'PLUGIN_TWITCH_OFFLINE');
        my $current = $song->pluginData('wmaMeta');
        my $initial_refresh = !$song->pluginData(
            'twitchLiveMetadataInitialized'
        );

        my $meta;
        if (!$initial_refresh && ref $current eq 'HASH') {
            $meta = {
                %$current,
                title => $title,
            };
        } else {
            $meta = {
                title  => $title,
                artist => lc($u->{login}),
                cover  => $u->{profileImageURL},
            };
            $song->pluginData('twitchLiveMetadataInitialized', 1);
        }

        _apply_song_metadata($client, $song, $meta);

        $cache->set(
            "twitch:live:$channel",
            $meta,
            Plugins::Twitch::Config::cache_ttl(),
        );
    });

    return;
}

1;
