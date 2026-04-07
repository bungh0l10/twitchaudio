package Plugins::Twitch::API;

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP;
use URI::Escape qw(uri_escape_utf8);
use Slim::Utils::Log qw(logger);

my $log = logger('plugin.twitch');
my $http = HTTP::Tiny->new(timeout => 8);
my $CLIENT_ID = "kimne78kx3ncx6brgo4mv6wki5h1ko";

# Fetch channel info
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
        $log->warn("Failed to fetch channel info for $login");
        $callback->();
    }
}

# Fetch audio-only HLS stream
sub getAudioUrl {
    my ($channel) = @_;
    return unless $channel;

    my $payload = {
        operationName => "PlaybackAccessToken_Template",
        query => 'query PlaybackAccessToken_Template($login: String!, $playerType: String!) { streamPlaybackAccessToken(channelName: $login, params: { platform: "web", playerBackend: "mediaplayer", playerType: $playerType }) { signature value } }',
        variables => { login => $channel, playerType => "embed" }
    };

    my $res = $http->post("https://gql.twitch.tv/gql", {
        headers => { "Client-ID" => $CLIENT_ID, "Content-Type" => "application/json" },
        content => encode_json($payload),
    });

    unless ($res->{success}) {
        $log->warn("Failed to get playback token for $channel");
        return;
    }

    my $data = decode_json($res->{content});
    my $tokenData = $data->{data}{streamPlaybackAccessToken} or return;

    my $sig   = $tokenData->{signature};
    my $token = $tokenData->{value};
    return unless $sig && $token;

    my $encoded = uri_escape_utf8($token);

    my $playlistUrl = "https://usher.ttvnw.net/api/channel/hls/$channel.m3u8"
        . "?sig=$sig&token=$encoded&allow_audio_only=true&allow_source=true";

    my $m3u = $http->get($playlistUrl);
    return unless $m3u->{success};

    my @lines = split /\n/, $m3u->{content};
    for (my $i=0; $i<@lines-1; $i++) {
        if ($lines[$i] =~ /audio_only/ && $lines[$i+1] =~ /^https/) {
            return $lines[$i+1];
        }
    }

    # fallback
    for my $line (@lines) { return $line if $line =~ /^https/; }
    return;
}

1;