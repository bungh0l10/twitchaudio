package Plugins::TwitchAudio::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Plugins::TwitchAudio::Twitch;

# Define logging category
my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.twitchaudio',
    defaultLevel => 'DEBUG',
    description  => 'PLUGIN_TWITCHAUDIO',
});

# Plugin name
sub name {
    return 'TwitchAudio';
}

# Called on server start
sub initPlugin {
    my $class = shift;

    $log->info("TwitchAudio Plugin initialized");

    # Register the protocol handler
    Slim::Player::Protocols::HTTP->registerHandler(
        'twitch', 'Plugins::TwitchAudio::ProtocolHandler'
    );

    return $class;
}

# Example feed handling
sub handleFeed {
    my ($class, $client, $params) = @_;
    $log->debug("handleFeed called");
}

# Example search function
sub searchChannel {
    my ($class, $client, $query) = @_;
    $query //= '';
    $log->debug("searchChannel called with query: '$query'");
}

1;