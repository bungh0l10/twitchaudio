package Plugins::TwitchAudio::ProtocolHandler;

BEGIN {
    warn "### Twitch ProtocolHandler loaded ###\n";
}

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Log;
use Plugins::TwitchAudio::Twitch;

my $log = Slim::Utils::Log->logger('plugin.twitchaudio');

sub canHandle {
    my ($class, $url) = @_;
    return $url =~ /^twitch:/;
}

sub canDirectStream {
    return 1;
}

sub isRemote { 1 }
sub isAudio  { 1 }

sub new {
    my ($class, $args) = @_;

    my $url = $args->{url};
    my ($channel) = $url =~ m|twitch://(.+)|;

    $log->error("ProtocolHandler triggered with URL: $url");

    unless ($channel) {
        $log->error("Invalid twitch URL");
        return;
    }

    $channel =~ s/\s+//g;
    $channel = lc $channel;

    $log->error("Extracted channel: $channel");

    my $streamUrl = Plugins::TwitchAudio::Twitch::getAudioUrl($channel);

    unless ($streamUrl) {
        $log->error("No stream URL returned!");
        return;
    }

    $log->error("Resolved stream URL: $streamUrl");

    $args->{url} = $streamUrl;

    return $class->SUPER::new($args);
}

1;