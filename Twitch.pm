package Plugins::TwitchAudio::Twitch;

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP;

my $http = HTTP::Tiny->new(timeout => 8);
my $CLIENT_ID = "kimne78kx3ncx6brgo4mv6wki5h1ko";

# fetch channel info
sub getChannel {
    my ($login, $callback) = @_;

    return $callback->() unless $login;

    my $payload = {
        query => 'query($login: String!) { user(login: $login) { id login profileImageURL(width: 300) stream { title viewersCount } } }',
        variables => { login => $login },
    };

    my $res = $http->post("https://gql.twitch.tv/gql", {
        headers => {
            "Client-ID" => $CLIENT_ID,
            "Content-Type" => "application/json",
        },
        content => encode_json($payload),
    });

    if ($res->{success}) {
        my $data = decode_json($res->{content});
        $callback->($data->{data});
    } else {
        $callback->();
    }
}

# fetch playable audio URL
sub getAudioUrl {
    my ($channel, $callback) = @_;

    # build GraphQL payload
    my $payload = {
        operationName => "PlaybackAccessToken_Template",
        query => 'query PlaybackAccessToken_Template($login: String!, $playerType: String!) { streamPlaybackAccessToken(channelName: $login, params: { platform: "web", playerBackend: "mediaplayer", playerType: $playerType }) { signature value } }',
        variables => { login => $channel, playerType => "embed" },
    };

    my $res = $http->post("https://gql.twitch.tv/gql", {
        headers => {
            "Client-ID" => $CLIENT_ID,
            "Content-Type" => "application/json",
        },
        content => encode_json($payload),
    });

    if ($res->{success}) {
        my $data = decode_json($res->{content});
        my $sig   = $data->{data}{streamPlaybackAccessToken}{signature};
        my $token = $data->{data}{streamPlaybackAccessToken}{value};

        if ($sig && $token) {
            my $url = "https://usher.ttvnw.net/api/channel/hls/$channel.m3u8?p=" . int(rand(1000000))
                    . "&sig=$sig&token=" . $token
                    . "&allow_audio_only=true";
            $callback->($url);
        } else {
            $callback->();
        }
    } else {
        $callback->();
    }
}

1;