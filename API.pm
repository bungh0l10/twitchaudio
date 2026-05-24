package Plugins::Twitch::API;

use strict;
use warnings;

use HTTP::Tiny;
use JSON::XS::VersionOneAndTwo qw(encode_json decode_json);
use URI;

use Slim::Utils::Log qw(logger);

use constant HTTP_TIMEOUT => 10;

my $log = logger('plugin.twitch');

my $CLIENT_ID = 'kimne78kx3ncx6brgo4mv6wki5h1ko';

my $http = HTTP::Tiny->new(
    timeout         => HTTP_TIMEOUT,
    keep_alive      => 1,
    max_connections => 10,
);

sub postJson {
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

    return unless $res->{success};

    my $data;

    return unless eval {
        $data = decode_json($res->{content});
        1;
    };

    return $data;
}

sub graphqlData {
    my ($payload, $label) = @_;

    my $data = postJson($payload);

    unless (ref $data eq 'HASH' && ref $data->{data} eq 'HASH') {
        $log->warn("twitch graphql invalid response: $label");
        return;
    }

    return $data->{data};
}

sub buildUri {
    my ($base, $params) = @_;

    my $uri = URI->new($base);
    $uri->query_form(%{$params || {}});

    return $uri;
}

sub extractAudioM3U8 {
    my ($content) = @_;

    return unless $content;

    my @lines = split /\n/, $content;

    for my $i (0 .. $#lines) {
        next unless $lines[$i] =~ /\baudio_only\b/i;

        for my $j ($i + 1 .. $#lines) {
            return $lines[$j] if $lines[$j] =~ /^https:\/\//;
        }
    }

    return;
}

sub getChannel {
    my ($login, $callback) = @_;

    return $callback->() unless defined $login && length $login;

    my $root = graphqlData({
        query => <<'GRAPHQL',
query($login: String!) {
    user(login: $login) {
        id
        login
        profileImageURL(width: 300)
        stream {
            title
            viewersCount
        }
    }
}
GRAPHQL
        variables => { login => $login },
    }, "getChannel:$login");

    return $callback->() unless $root;

    return $callback->($root);
}

sub getAudioUrl {
    my ($channel) = @_;

    return unless defined $channel && length $channel;

    my $root = graphqlData({
        operationName => 'PlaybackAccessToken_Template',
        query => <<'GRAPHQL',
query PlaybackAccessToken_Template($login: String!, $playerType: String!) {
    streamPlaybackAccessToken(
        channelName: $login,
        params: {
            platform: "web",
            playerBackend: "mediaplayer",
            playerType: $playerType
        }
    ) {
        signature
        value
    }
}
GRAPHQL

        variables => {
            login      => $channel,
            playerType => 'embed',
        },
    }, "getAudioUrl:$channel");

    my $token = $root->{streamPlaybackAccessToken} if $root;

    return unless $token && $token->{signature} && $token->{value};

    my $uri = buildUri(
        "https://usher.ttvnw.net/api/v2/channel/hls/$channel.m3u8",
        {
            sig              => $token->{signature},
            token            => $token->{value},
            allow_audio_only => 'true',
            allow_source     => 'true',
        }
    );

    my $res = $http->get($uri->as_string);

    return unless $res->{success};

    return extractAudioM3U8($res->{content});
}

sub getVods {
    my ($login, $limit, $callback) = @_;

    return $callback->() unless defined $login && length $login;

    $limit ||= 10;

    my $root = graphqlData({
        query => <<'GRAPHQL',
query($login: String!, $limit: Int!) {
    user(login: $login) {

        highlights: videos(
            first: $limit,
            types: HIGHLIGHT,
            sort: TIME
        ) {
            edges {
                node {
                    id
                    title
                    createdAt
                    lengthSeconds
                    thumbnailURLs(width: 320, height: 180)
                }
            }
        }

        archives: videos(
            first: $limit,
            types: ARCHIVE,
            sort: TIME
        ) {
            edges {
                node {
                    id
                    title
                    createdAt
                    lengthSeconds
                    thumbnailURLs(width: 320, height: 180)
                }
            }
        }

    }
}
GRAPHQL
        variables => {
            login => $login,
            limit => $limit,
        },
    }, "getVods:$login");

    return $callback->() unless $root;

    return $callback->($root);
}

sub getVodAudioUrl {
    my ($vod_id) = @_;

    return unless defined $vod_id && $vod_id =~ /^\d+$/;

    my $root = graphqlData({
        operationName => 'PlaybackAccessToken',
        extensions => {
            persistedQuery => {
                version    => 1,
                sha256Hash => 'ed230aa1e33e07eebb8928504583da78a5173989fadfb1ac94be06a04f3cdbe9',
            }
        },
        variables => {
            isLive     => 0,
            isVod      => 1,
            vodID      => $vod_id,
            login      => '',
            platform   => 'web',
            playerType => 'embed',
        },
    }, "getVodAudioUrl:$vod_id");

    my $token = $root->{videoPlaybackAccessToken} if $root;

    return unless $token && $token->{signature} && $token->{value};

    my $uri = buildUri(
        "https://usher.ttvnw.net/vod/v2/$vod_id.m3u8",
        {
            nauthsig         => $token->{signature},
            nauth            => $token->{value},
            allow_audio_only => 'true',
            allow_source     => 'true',
        }
    );

    my $res = $http->get($uri->as_string);

    return unless $res->{success};

    return extractAudioM3U8($res->{content});
}

sub getVodMeta {
    my ($vod_id, $callback) = @_;

    return $callback->() unless defined $vod_id && length $vod_id;

    my $root = graphqlData({
        query => <<'GRAPHQL',
query($id: ID!) {
    video(id: $id) {
        id
        title
        createdAt
        lengthSeconds
        owner {
            login
        }
        thumbnailURLs(width: 640, height: 360)
    }
}
GRAPHQL

        variables => { id => "$vod_id" },
    }, "getVodMeta:$vod_id");

    my $v = $root->{video} if $root;

    unless ($v) {
        $log->warn("twitch missing vod meta vod_id=$vod_id");
        return $callback->();
    }

    return $callback->({
        id        => $v->{id},
        title     => $v->{title},
        artist    => lc($v->{owner}{login} // ''),
        thumbnail => (
            ref $v->{thumbnailURLs} eq 'ARRAY'
                ? ($v->{thumbnailURLs}[0] // '')
                : ''
        ),
        duration  => $v->{lengthSeconds} || 0,
    });
}

1;