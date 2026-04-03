package Plugins::TwitchAudio::ProtocolHandler;

use strict;
use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Log;
use Slim::Utils::Scanner::Remote;
use Slim::Player::Song;
use Plugins::TwitchAudio::Twitch;

# Logging
my $log = Slim::Utils::Log->logger('plugin.twitchaudio');

# Convert twitch://channel into a playable Slim::Player::Song
sub scanUrl {
    my ($class, $uri, $args) = @_;
    my ($channel) = $uri =~ m|twitch://(.+)|;

    $log->debug("scanUrl called for channel: $channel");

    my $url = Plugins::TwitchAudio::Twitch::getAudioUrl($channel);

    if ($url) {
        $log->info("Found HLS stream for $channel: $url");

        my $client = $args->{client}->master;
        Slim::Utils::Scanner::Remote->scanURL($url, $args);

        $client->playingSong->pluginData({
            icon   => '',
            cover  => '',
            artist => "Twitch: $channel",
            title  => "Live audio"
        });

        Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
    }
    else {
        $log->warn("No stream available for $channel");
    }
}

1;