package Plugins::TwitchAudio::Twitch;

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP;
use URI::Escape qw(uri_escape_utf8);
use Slim::Utils::Log;

my $log = logger('plugin.twitchaudio');
my $http = HTTP::Tiny->new(timeout => 8);

my $CLIENT_ID = "kimne78kx3ncx6brgo4mv6wki5h1ko";

sub getAudioUrl {
    my ($channel) = @_;

    return unless $channel;

    # Normalize
    $channel =~ s/^https?:\/\/(www\.)?twitch\.tv\///;
    $channel =~ s/\s+//g;
    $channel = lc $channel;

    $log->debug("Fetching Twitch stream for: $channel");

    my $payload = {
        operationName => "PlaybackAccessToken_Template",
        query => 'query PlaybackAccessToken_Template($login: String!, $playerType: String!) { streamPlaybackAccessToken(channelName: $login, params: { platform: "web", playerBackend: "mediaplayer", playerType: $playerType }) { signature value } }',
        variables => {
            login => $channel,
            playerType => "embed"
        }
    };

    my $res = $http->post("https://gql.twitch.tv/gql", {
        headers => {
            "Client-ID"    => $CLIENT_ID,
            "Content-Type" => "application/json",
        },
        content => encode_json($payload),
    });

    return unless $res->{success};
    $log->debug("res: $res");

    my $data = eval { decode_json($res->{content}) };
    return if $@;

    my $tokenData = $data->{data}{streamPlaybackAccessToken};
    return unless $tokenData;

    my $sig   = $tokenData->{signature};
    my $token = $tokenData->{value};

    return unless $sig && $token;

    my $p = int(rand(1000000));
    my $encoded = uri_escape_utf8($token);

    my $playlistUrl = "https://usher.ttvnw.net/api/channel/hls/$channel.m3u8"
        . "?p=$p&sig=$sig&token=$encoded&allow_audio_only=true&allow_source=true";

    my $m3u = $http->get($playlistUrl);
    return unless $m3u->{success};

    my @lines = split /\n/, $m3u->{content};

    my ($audio, $fallback);

    for (my $i = 0; $i < @lines - 1; $i++) {
        my $meta = $lines[$i];
        my $url  = $lines[$i + 1];

        next unless $url =~ /^https/;

        if ($meta =~ /audio_only/) {
            $audio = $url;
            last;
        }

        if ($meta =~ /chunked/ && !$fallback) {
            $fallback = $url;
        }

        $fallback ||= $url;
    }

    return $audio || $fallback;
}

1;