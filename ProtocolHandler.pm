package Plugins::TwitchAudio::ProtocolHandler;

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Log;
use Plugins::TwitchAudio::Twitch;

my $log = Slim::Utils::Log->logger('plugin.twitchaudio');

sub canHandle {
    my ($class, $url) = @_;
    return $url =~ /^twitch:/ ? 1 : 0;
}

sub isRemote { 1 }
sub isAudio  { 1 }

sub new {
    my ($class, $args) = @_;
    my $url = $args->{url};

    $log->error("HANDLER USED: $url");  # sollte erscheinen

    my ($channel) = $url =~ m|twitch://(.+)|;
    my $streamUrl = Plugins::TwitchAudio::Twitch::getAudioUrl($channel);

    unless ($streamUrl) {
        $log->error("NO STREAM");
        return;
    }

    $args->{url} = $streamUrl;

    return $class->SUPER::new($args);
}

1;