package Plugins::Twitch::ProtocolHandler;

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTPS);
use Slim::Utils::Log;
use Plugins::Twitch::API;

my $log = Slim::Utils::Log->logger('plugin.twitch');

sub new {
    my ($class, $args) = @_;
    my $url = $args->{url};

    # Already HTTP/HTTPS → direkt abspielen
    if ($url =~ /^https/) {
        return $class->SUPER::new($args);
    }

    # twitch://channel → getAudioUrl
    my ($channel) = $url =~ m|twitch://(.+)|;
    my $streamUrl = Plugins::Twitch::API::getAudioUrl($channel);

    unless ($streamUrl) {
        $log->warn("No stream URL available for $channel");
        return;
    }

    $args->{url} = $streamUrl;
    return $class->SUPER::new($args);
}

1;