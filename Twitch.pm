package Plugins::TwitchAudio::Twitch;

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP;
use URI::Escape qw(uri_escape_utf8);
use Slim::Utils::Log;

my $log = Slim::Utils::Log->logger('plugin.twitchaudio');
my $http = HTTP::Tiny->new(timeout => 8);
my $CLIENT_ID = "kimne78kx3ncx6brgo4mv6wki5h1ko";

# HLS Audio URL
sub getAudioUrl {
    my ($channel) = @_;
    return unless $channel;

    $channel =~ s/^https?:\/\/(www\.)?twitch\.tv\///;
    $channel =~ s/\s+//g;
    $channel = lc $channel;

    $log->debug("Fetching Twitch stream for: $channel");

    my $payload = {
        operationName => "PlaybackAccessToken_Template",
        query => 'query PlaybackAccessToken_Template($login: String!, $playerType: String!) { streamPlaybackAccessToken(channelName: $login, params: { platform: "web", playerBackend: "mediaplayer", playerType: $playerType }) { signature value } }',
        variables => { login => $channel, playerType => "embed" }
    };

    my $res = $http->post("https://gql.twitch.tv/gql", {
        headers => {
            "Client-ID" => $CLIENT_ID,
            "Content-Type" => "application/json",
        },
        content => encode_json($payload),
    });

    return unless $res->{success};
    my $data = decode_json($res->{content});
    my $tokenData = $data->{data}{streamPlaybackAccessToken} or return;

    my $sig   = $tokenData->{signature};
    my $token = $tokenData->{value};
    return unless $sig && $token;

    my $p       = int(rand(1000000));
    my $encoded = uri_escape_utf8($token);

    my $playlistUrl = "https://usher.ttvnw.net/api/channel/hls/$channel.m3u8"
        . "?p=$p&sig=$sig&token=$encoded&allow_audio_only=true&allow_source=true";

    my $m3u = $http->get($playlistUrl);
    return unless $m3u->{success};

    my @lines = split /\n/, $m3u->{content};
    for (my $i = 0; $i < @lines - 1; $i++) {
        if ($lines[$i] =~ /audio_only/ && $lines[$i+1] =~ /^https/) {
            $log->info("Audio-only stream found for $channel");
            return $lines[$i+1];
        }
    }

    # fallback auf erste HTTPS-Zeile
    for my $line (@lines) {
        return $line if $line =~ /^https/;
    }

    return;
}

# Channel info
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

1;