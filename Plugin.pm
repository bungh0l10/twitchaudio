package Plugins::TwitchAudio::Plugin;

use strict;
use warnings;

use Slim::Utils::Log;
use Plugins::TwitchAudio::Twitch;
use Plugins::TwitchAudio::ProtocolHandler;

# register a logging category
my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.twitchaudio',
    defaultLevel => 'DEBUG',
    description  => 'PLUGIN_TWITCHAUDIO_NAME',
});

sub initPlugin {
    $log->info("Initializing TwitchAudio plugin");

    # register protocol handler
    Slim::Player::Protocols->registerHandler('twitch', 'Plugins::TwitchAudio::ProtocolHandler');
}

# handle search requests
sub searchChannel {
    my ($class, $query, $callback) = @_;
    $log->debug("searchChannel called with query: '$query'");

    return $callback->([]) unless $query;

    Plugins::TwitchAudio::Twitch::getChannel($query, sub {
        my $data = shift;
        my $items = [];

        if ($data && $data->{user}) {
            my $user = $data->{user};
            push @$items, {
                uri   => "twitch://channel/" . $user->{login},
                title => $user->{stream} ? $user->{stream}->{title} : $user->{login},
                icon  => $user->{profileImageURL},
                artist => $user->{login},
            };
        }

        $callback->($items);
    });
}

1;