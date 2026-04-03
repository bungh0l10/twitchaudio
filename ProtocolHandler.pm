package Plugins::TwitchAudio::ProtocolHandler;

use strict;
use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Log;
use Plugins::TwitchAudio::Twitch;

my $log = logger('plugin.twitchaudio');

sub scanUrl {
    my ($class, $uri, $args) = @_;
    $log->debug("scanUrl called with URI: $uri");

    if ($uri =~ m|twitch://channel/(.+)|) {
        my $channel = $1;
        Plugins::TwitchAudio::Twitch::getAudioUrl($channel, sub {
            my $url = shift;
            if ($url) {
                Slim::Utils::Scanner::Remote->scanURL($url, $args);
            } else {
                $log->warn("No audio URL found for channel $channel");
            }
        });
    }
}

1;