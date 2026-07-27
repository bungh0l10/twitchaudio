package Plugins::Twitch::API;

use strict;
use warnings;

use JSON::XS qw(encode_json decode_json);
use URI;
use Try::Tiny;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log qw(logger);

use Plugins::Twitch::Config ();
use Plugins::Twitch::HLS::Playlist ();

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
        return $callback->(_extract_audio_m3u8($content, $url));
    });

    return;
}

sub _hls_attributes {
    my ($text) = @_;
    return unless defined $text;

    my %attributes;
    pos($text) = 0;
    while (pos($text) < length($text)) {
        return unless $text =~ /\G\s*([A-Z0-9-]+)\s*=\s*/igc;
        my $name = uc $1;
        my $value;

        if (substr($text, pos($text), 1) eq '"') {
            return unless $text =~ /\G"((?:[^"\\]|\\.)*)"\s*/gc;
            $value = $1;
            $value =~ s/\\(.)/$1/g;
        } else {
            return unless $text =~ /\G([^,]*)\s*/gc;
            $value = $1;
            $value =~ s/^\s+|\s+$//g;
        }

        $attributes{$name} = $value;
        last if pos($text) == length($text);
        return unless $text =~ /\G,\s*/gc;
    }

    return \%attributes;
}

sub _is_audio_only_rendition {
    my ($attributes) = @_;
    return unless ref $attributes eq 'HASH';

    for my $name (qw(NAME VIDEO AUDIO GROUP-ID)) {
        return 1 if defined $attributes->{$name}
            && lc($attributes->{$name}) eq 'audio_only';
    }

    return;
}

sub _resolve_master_uri {
    my ($reference, $master_url) = @_;
    return Plugins::Twitch::HLS::Playlist->resolve_https_url(
        $reference,
        $master_url,
    );
}

sub _extract_audio_m3u8 {
    my ($content, $master_url) = @_;

    return unless $content && $content =~ /^#EXTM3U(?:\s|$)/;
    return unless _resolve_master_uri($master_url, $master_url);

    my $awaiting_stream_uri = 0;
    for my $line (split /\r?\n/, $content) {
        next unless $line =~ /\S/;

        if ($line =~ /^#EXT-X-MEDIA:(.*)$/i) {
            $awaiting_stream_uri = 0;
            my $attributes = _hls_attributes($1) or next;
            next unless uc($attributes->{TYPE} // '') eq 'AUDIO';
            next unless _is_audio_only_rendition($attributes);
            next unless defined $attributes->{URI};
            return _resolve_master_uri($attributes->{URI}, $master_url);
        }

        if ($line =~ /^#EXT-X-STREAM-INF:(.*)$/i) {
            my $attributes = _hls_attributes($1);
            $awaiting_stream_uri = _is_audio_only_rendition($attributes)
                ? 1 : 0;
            next;
        }

        if ($awaiting_stream_uri && $line !~ /^#/) {
            return _resolve_master_uri($line, $master_url);
        }

        # A stream URI must be the next non-empty line after its
        # EXT-X-STREAM-INF tag. Another tag invalidates the association.
        $awaiting_stream_uri = 0;
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
