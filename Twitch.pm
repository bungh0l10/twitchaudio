package Plugins::TwitchAudio::Twitch;

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP;
use URI::Escape qw(uri_escape);
use Slim::Utils::Log;

my $log = logger('plugin.twitchaudio');

my $http = HTTP::Tiny->new(timeout => 8);
my $CLIENT_ID = "kimne78kx3ncx6brgo4mv6wki5h1ko";

sub getAudioUrl {
    my ($channel) = @_;

    $log->debug("Fetching audio URL for channel: '$channel'");

    return unless $channel;

    # --- Token request ---
    my $payload = {
        operationName => "PlaybackAccessToken_Template",
        query => 'query PlaybackAccessToken_Template($login: String!, $playerType: String!) {
                    streamPlaybackAccessToken(channelName: $login, params: { platform: "web", playerBackend: "mediaplayer", playerType: $playerType }) {
                        signature value
                    }
                  }',
        variables => {
            login => $channel,
            playerType => "embed"
        }
    };

    my $res = $http->post("https://gql.twitch.tv/gql", {
        headers => {
            "Client-ID" => $CLIENT_ID,
            "Content-Type" => "application/json",
        },
        content => encode_json($payload),
    });

    unless ($res->{success}) {
        $log->warn("HTTP request failed for channel '$channel': $res->{status} $res->{reason}");
        return;
    }

    my $data = decode_json($res->{content});
    $log->debug("Twitch GraphQL response: " . $res->{content});

    my $sig   = $data->{data}{streamPlaybackAccessToken}{signature};
    my $token = $data->{data}{streamPlaybackAccessToken}{value};

    unless ($sig && $token) {
        $log->warn("No signature/token returned for '$channel'");
        return;
    }

    # --- Build HLS URL ---
    my $p = int(rand(1000000));
    my $encoded = uri_escape($token);

    my $url = "https://usher.ttvnw.net/api/channel/hls/$channel.m3u8"
        . "?p=$p&sig=$sig&token=$encoded&allow_audio_only=true";

    my $m3u = $http->get($url);

    unless ($m3u->{success}) {
        $log->warn("Failed to fetch m3u8 playlist for '$channel'");
        return;
    }

    my @lines = split /\n/, $m3u->{content};

    for (my $i = 0; $i < @lines - 1; $i++) {
        if ($lines[$i] =~ /audio_only/ && $lines[$i+1] =~ /^https/) {
            $log->debug("Found audio-only URL: $lines[$i+1]");
            return $lines[$i+1];
        }
    }

    $log->warn("No audio-only stream found for '$channel'");
    return;
}

1;