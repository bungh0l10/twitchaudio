package Plugins::Twitch::API;

use strict;
use warnings;

use JSON::XS qw(encode_json decode_json);
use URI;
use Try::Tiny;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log qw(logger);

use Plugins::Twitch::Config ();

use constant {
    HTTP_TIMEOUT => 10,
    GQL_URL      => 'https://gql.twitch.tv/gql',
};

my $log = logger('plugin.twitch');

sub _has_text {
    my ($value) = @_;

    return defined $value && length $value;
}

sub _json_bool {
    my ($value) = @_;
    return $value ? \1 : \0;
}

sub _request {
    my ($method, $url, $headers, $body, $callback) = @_;

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my ($response) = @_;
            return $callback->($response->content);
        },
        sub {
            my ($response, $error, $http_response) = @_;

            my $status = $http_response ? $http_response->status_line : $error;
            $log->error("Twitch HTTP $method failed for $url: " . ($status || 'unknown error'));

            return $callback->();
        },
        { timeout => HTTP_TIMEOUT },
    );

    if ($method eq 'POST') {
        $http->post($url, %$headers, $body);
    }
    else {
        $http->get($url, %$headers);
    }

    return;
}

sub _post_json {
    my ($payload, $callback) = @_;

    _request(
        'POST',
        GQL_URL,
        {
            'Client-ID'    => Plugins::Twitch::Config::client_id(),
            'Content-Type' => 'application/json',
        },
        encode_json($payload),
        sub {
            my ($content) = @_;
            return $callback->() unless $content;

            my $data;

            try {
                $data = decode_json($content);
            }
            catch {
                $log->error("Twitch JSON decode failed: $_");
            };

            if ($data && $data->{errors}) {
                my @messages = map { $_->{message} // 'unknown GraphQL error' } @{ $data->{errors} };
                $log->error('Twitch GraphQL error: ' . join('; ', @messages));
            }

            return $callback->($data);
        },
    );

    return;
}

sub _graphql_data {
    my ($payload, $label, $callback) = @_;

    _post_json($payload, sub {
        my ($data) = @_;

        unless (ref $data eq 'HASH' && ref $data->{data} eq 'HASH') {
            $log->error("Twitch GraphQL invalid response: $label");
            return $callback->();
        }

        return $callback->($data->{data});
    });

    return;
}

sub _build_uri {
    my ($base, $params) = @_;

    my $uri = URI->new($base);
    $uri->query_form(%{$params || {}});

    return $uri->as_string;
}

sub _get_audio_playlist {
    my ($url, $callback) = @_;

    _request('GET', $url, {}, undef, sub {
        my ($content) = @_;
        return $callback->(_extract_audio_m3u8($content));
    });

    return;
}

sub _extract_audio_m3u8 {
    my ($content) = @_;

    return unless $content;

    my @lines = split /\n/, $content;
    return unless @lines >= 2;

    for my $match (
        qr/\bSTABLE-VARIANT-ID="audio_only"/i,
        qr/\baudio_only\b/i,
    ) {
        for my $i (0 .. $#lines - 1) {
            next unless $lines[$i] =~ $match;

            my $uri = $lines[$i + 1] =~ s/\r\z//r;
            return $uri if $uri =~ m{^https://};
        }
    }

    return;
}

sub getChannel {
    my ($login, $callback) = @_;

    return $callback->() unless _has_text($login);

    _graphql_data({
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
    }, "getChannel:$login", $callback);

    return;
}

sub getAudioUrl {
    my ($channel, $callback) = @_;

    return $callback->() unless _has_text($channel);

    _graphql_data({
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
    }, "getAudioUrl:$channel", sub {
        my ($root) = @_;

        my $token = $root && $root->{streamPlaybackAccessToken};
        unless ($token && $token->{signature} && $token->{value}) {
            $log->error("Twitch missing live playback token for $channel");
            return $callback->();
        }

        my $url = _build_uri(
            "https://usher.ttvnw.net/api/v2/channel/hls/$channel.m3u8",
            {
                sig              => $token->{signature},
                token            => $token->{value},
                allow_audio_only => 'true',
                allow_source     => 'true',
            },
        );

        return _get_audio_playlist($url, $callback);
    });

    return;
}

sub getVods {
    my ($login, $limit, $callback) = @_;

    return $callback->() unless _has_text($login);

    $limit ||= 10;

    _graphql_data({
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
    }, "getVods:$login", $callback);

    return;
}

sub getVodAudioUrl {
    my ($vod_id, $callback) = @_;

    return $callback->() unless _has_text($vod_id) && $vod_id =~ /^\d+$/;

    _graphql_data({
        operationName => 'PlaybackAccessToken',
        extensions => {
            persistedQuery => {
                version    => 1,
                sha256Hash => 'ed230aa1e33e07eebb8928504583da78a5173989fadfb1ac94be06a04f3cdbe9',
            },
        },
        variables => {
            isLive     => _json_bool(0),
            isVod      => _json_bool(1),
            vodID      => $vod_id,
            login      => '',
            platform   => 'web',
            playerType => 'embed',
        },
    }, "getVodAudioUrl:$vod_id", sub {
        my ($root) = @_;

        my $token = $root && $root->{videoPlaybackAccessToken};
        unless ($token && $token->{signature} && $token->{value}) {
            $log->error("Twitch missing VOD playback token for $vod_id");
            return $callback->();
        }

        my $url = _build_uri(
            "https://usher.ttvnw.net/vod/v2/$vod_id.m3u8",
            {
                nauthsig         => $token->{signature},
                nauth            => $token->{value},
                allow_audio_only => 'true',
                allow_source     => 'true',
            },
        );

        return _get_audio_playlist($url, $callback);
    });

    return;
}

sub getVodMeta {
    my ($vod_id, $callback) = @_;

    return $callback->() unless _has_text($vod_id);

    _graphql_data({
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
    }, "getVodMeta:$vod_id", sub {
        my ($root) = @_;

        my $vod = $root && $root->{video};
        unless ($vod) {
            $log->error("Twitch missing VOD metadata for $vod_id");
            return $callback->();
        }

        return $callback->({
            id        => $vod->{id},
            title     => $vod->{title},
            artist    => lc($vod->{owner}{login} // ''),
            thumbnail => ref $vod->{thumbnailURLs} eq 'ARRAY'
                ? ($vod->{thumbnailURLs}[0] // '')
                : '',
            duration  => $vod->{lengthSeconds} || 0,
        });
    });

    return;
}

1;
