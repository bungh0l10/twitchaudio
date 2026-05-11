package Plugins::Twitch::API;

use strict;
use warnings;

use HTTP::Tiny;
use JSON::PP qw(encode_json decode_json);
use URI::Escape qw(uri_escape_utf8);
use Try::Tiny;
use Slim::Utils::Log qw(logger);

use constant {
    HTTP_TIMEOUT => 10,
};

my $log = logger('plugin.twitch');

my $http = HTTP::Tiny->new(timeout => HTTP_TIMEOUT);
my $CLIENT_ID = 'kimne78kx3ncx6brgo4mv6wki5h1ko';

sub _post_json {
    my ($payload) = @_;

    my $res = $http->post(
        'https://gql.twitch.tv/gql',
        {
            headers => {
                'Client-ID'    => $CLIENT_ID,
                'Content-Type' => 'application/json',
            },
            content => encode_json($payload),
        }
    );

    unless ($res->{success}) {
        $log->warn(
            'HTTP POST failed: '
          . ($res->{status} // '?') . ' '
          . ($res->{reason} // '')
        );
        return;
    }

    my $data;

    try {
        $data = decode_json($res->{content});
    }
    catch {
        $log->warn("JSON decode failed: $_");
        return;
    };

    return $data;
}

sub _extract_audio_m3u8 {
    my ($content) = @_;

    return unless $content;

    my @lines = split /\n/, $content;

    for (my $i = 0; $i < @lines; $i++) {
        next unless $lines[$i] =~ /\baudio_only\b/i;

        for my $j ($i + 1 .. $#lines) {
            return $lines[$j] if $lines[$j] =~ m{^https://};
        }
    }

    return;
}

sub getChannel {
    my ($login, $callback) = @_;

    return $callback->() unless $login;

    my $data = _post_json({
        query => 'query($login: String!) { user(login: $login) { id login profileImageURL(width: 300) stream { title viewersCount } } }',
        variables => { login => $login },
    });

    my $root = $data->{data} or do {
        $log->warn("Invalid channel response for $login");
        return $callback->();
    };

    $log->debug("getChannel OK for $login");

    return $callback->($root);
}

sub getAudioUrl {
    my ($channel) = @_;

    return unless $channel;

    my $data = _post_json({
        operationName => 'PlaybackAccessToken_Template',
        query => 'query PlaybackAccessToken_Template($login: String!, $playerType: String!) { streamPlaybackAccessToken(channelName: $login, params: { platform: "web", playerBackend: "mediaplayer", playerType: $playerType }) { signature value } }',
        variables => {
            login      => $channel,
            playerType => 'embed',
        },
    });

    my $root = $data->{data} or return;

    my $token = $root->{streamPlaybackAccessToken} or do {
        $log->warn("No playback token for $channel");
        return;
    };

    return unless $token->{signature} && $token->{value};

    my $sig     = $token->{signature};
    my $encoded = uri_escape_utf8($token->{value});

    my $playlist =
        "https://usher.ttvnw.net/api/v2/channel/hls/$channel.m3u8"
      . "?sig=$sig&token=$encoded&allow_audio_only=true&allow_source=true";

    $log->debug("LIVE m3u8: $playlist");

    my $res = $http->get($playlist);

    unless ($res->{success}) {
        $log->warn(
            "Failed to fetch m3u8 for $channel: "
          . ($res->{status} // '?')
        );
        return;
    }

    my $audio = _extract_audio_m3u8($res->{content});

    $log->debug("audio_only URL: $audio") if $audio;

    return $audio;
}

sub getVods {
    my ($login, $limit, $callback) = @_;

    return $callback->() unless $login;

    $limit ||= 10;

    my $data = _post_json({
        query => 'query($login: String!, $limit: Int!) { user(login: $login) { videos(first: $limit, types: HIGHLIGHT, sort: TIME) { edges { node { id title createdAt lengthSeconds thumbnailURLs(width: 320, height: 180) } } } } }',
        variables => {
            login => $login,
            limit => $limit,
        },
    });

    my $root = $data->{data} or do {
        $log->warn("Invalid VOD response for $login");
        return $callback->();
    };

    return $callback->($root);
}

sub getVodAudioUrl {
    my ($vod_id) = @_;

    return unless $vod_id;

    my $data = _post_json({
        operationName => 'PlaybackAccessToken',
        extensions => {
            persistedQuery => {
                version => 1,
                sha256Hash => 'ed230aa1e33e07eebb8928504583da78a5173989fadfb1ac94be06a04f3cdbe9',
            }
        },
        variables => {
            isLive     => JSON::PP::false,
            isVod      => JSON::PP::true,
            vodID      => $vod_id,
            login      => '',
            platform   => 'web',
            playerType => 'embed',
        },
    });

    my $root = $data->{data} or return;

    my $token = $root->{videoPlaybackAccessToken} or do {
        $log->warn("No VOD token for $vod_id");
        return;
    };

    return unless $token->{signature} && $token->{value};

    my $sig   = $token->{signature};
    my $value = uri_escape_utf8($token->{value});

    my $url =
        "https://usher.ttvnw.net/vod/v2/$vod_id.m3u8"
      . "?nauthsig=$sig"
      . "&nauth=$value"
      . "&allow_audio_only=true"
      . "&allow_source=true";

    my $res = $http->get($url);

    unless ($res->{success}) {
        $log->warn(
            "Failed to fetch VOD m3u8 for $vod_id: "
          . ($res->{status} // '?')
        );
        return;
    }

    return _extract_audio_m3u8($res->{content});
}

sub getVodMeta {
    my ($vod_id, $callback) = @_;

    return $callback->() unless $vod_id;

    my $data = _post_json({
        query => '
            query($id: ID!) {
                video(id: $id) {
                    id
                    title
                    createdAt
                    lengthSeconds
                    owner { login }
                    thumbnailURLs(width: 640, height: 360)
                }
            }
        ',
        variables => {
            id => "$vod_id",
        },
    });

    my $root = $data->{data} or return $callback->();

    my $v = $root->{video} or do {
        $log->warn("No VOD meta for $vod_id");
        return $callback->();
    };

    return $callback->({
        id        => $v->{id},
        title     => $v->{title},
        artist    => lc($v->{owner}{login} // ''),
        thumbnail => $v->{thumbnailURLs}[0] // '',
        duration  => $v->{lengthSeconds} || 0,
    });
}

1;
