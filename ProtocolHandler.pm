package Plugins::TwitchAudio::ProtocolHandler;

use strict;
use base qw(Slim::Player::Protocols::HTTPS);
use Slim::Utils::Log;
use Plugins::TwitchAudio::Twitch;

my $log = logger('plugin.twitchaudio');

# Handle twitch:// URLs
sub scanUrl {
    my ($class, $uri, $args) = @_;
    $log->debug("scanUrl called with URI: '$uri'");

    my ($channel) = $uri =~ m{twitch://(.+)};
    unless ($channel) {
        $log->warn("No channel parsed from URI '$uri'");
        return;
    }

    # Fetch actual audio URL
    my $url = Plugins::TwitchAudio::Twitch::getAudioUrl($channel);

    unless ($url) {
        $log->warn("No playable URL for channel '$channel'");
        return;
    }

    $log->debug("Scanning remote URL: $url");

    Slim::Utils::Scanner::Remote->scanURL($url, $args);

    # Add metadata to currently playing song
    if ($args->{client} && $args->{client}->can('playingSong')) {
        my $client = $args->{client}->master;
        $client->playingSong->pluginData({
            title  => $channel,
            artist => "Twitch Audio",
            icon   => "https://static.twitchcdn.net/assets/favicon-32-e29e246c157142c94346.png",
            cover  => "https://static.twitchcdn.net/assets/favicon-32-e29e246c157142c94346.png",
        });
        Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
    }
}

1;