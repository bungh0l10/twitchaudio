package Plugins::Twitch::ProtocolHandler;

use strict;
use warnings;

use parent qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Log;
use Slim::Utils::Scanner::Remote ();
use Slim::Utils::Cache;
use Slim::Control::Request ();

use Plugins::Twitch::API ();
use Plugins::Twitch::Config ();
use Plugins::Twitch::HLSStream ();

my $log = logger('plugin.twitch');

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

sub canDirectStream { 0 }
sub isAudio          { 1 }
sub isRemote         { 1 }
sub canSeek          { 0 }
sub songBytes        { 0 }

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

    $fetch_url->(sub {
        my ($stream_url) = @_;
        return unless $stream_url;

        my $stream_type = $media_id =~ /^live:/ ? 'LIVE' : 'VOD';
        $log->info("TWITCH $stream_type STREAM URL: $stream_url");

        my $native_url = _native_hls_url($stream_url);
        _set_hls_args($args);
        Slim::Utils::Scanner::Remote->scanURL($native_url, $args);
        _applyInitialMetadata($client, $media_id);

        return;
    });

    return;
}

sub _applyInitialMetadata {
    my ($client, $id) = @_;

    return unless $client && $id;

    my $song = $client->playingSong or return;
    my $cache = Slim::Utils::Cache->new;

    if ($id =~ /^vod:(\d+)$/) {
        my $vod_id = $1;

        my $meta = $cache->get("twitch:vod:$vod_id");

        if ($meta) {
            $song->pluginData({ wmaMeta => $meta });
            Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
            return;
        }

        Plugins::Twitch::API::getVodMeta($vod_id, sub {
            my ($vod) = @_;

            return unless $vod;

            my $current = $client->playingSong or return;

            my $meta = {
                title  => $vod->{title} // 'VOD',
                artist => $vod->{artist},
                cover  => $vod->{thumbnail},
            };

            $current->pluginData({ wmaMeta => $meta });
            Slim::Control::Request::notifyFromArray($client, ['newmetadata']);

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

    my $meta = $cache->get("twitch:live:$channel");

    if ($meta) {
        $song->pluginData({ wmaMeta => $meta });
        Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
        return;
    }

    Plugins::Twitch::API::getChannel($channel, sub {
        my ($data) = @_;

        return unless $data && $data->{user};

        my $u = $data->{user};

        my $current = $client->playingSong or return;

        my $meta = {
            title  => $u->{stream}->{title} // 'Offline',
            artist => lc($u->{login}),
            cover  => $u->{profileImageURL},
        };

        $current->pluginData({ wmaMeta => $meta });
        Slim::Control::Request::notifyFromArray($client, ['newmetadata']);

        $cache->set(
            "twitch:live:$channel",
            $meta,
            Plugins::Twitch::Config::cache_ttl(),
        );
    });

    return;
}

1;
