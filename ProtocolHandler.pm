package Plugins::TwitchAudio::ProtocolHandler;

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTP);

use Slim::Utils::Log;
use Plugins::TwitchAudio::Twitch;

my $log = Slim::Utils::Log->logger('plugin.twitchaudio');

sub new {
    my ($class, $args) = @_;

    my $url = $args->{url};
    my ($channel) = $url =~ m|twitch://(.+)|;

    unless ($channel) {
        $log->error("Invalid twitch URL: $url");
        return;
    }

    $channel =~ s/\s+//g;
    $channel = lc $channel;

    $log->info("Resolving Twitch channel: $channel");

    my $streamUrl = Plugins::TwitchAudio::Twitch::getAudioUrl($channel);

    unless ($streamUrl) {
        $log->error("No stream URL for $channel");
        return;
    }

    $log->info("Stream URL resolved: $streamUrl");

    $args->{url} = $streamUrl;

    return $class->SUPER::new($args);
}

1;