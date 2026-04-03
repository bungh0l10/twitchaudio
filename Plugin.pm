package Plugins::TwitchAudio::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Plugins::TwitchAudio::Twitch;
use Plugins::TwitchAudio::ProtocolHandler;

my $prefs = preferences('plugin.twitchaudio');

# Proper log category
my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.twitchaudio',
    defaultLevel => 'WARN',
    description  => 'TwitchAudio Plugin',
    logGroups    => 'SCANNER',
});

sub initPlugin {
    my $class = shift;
    $log->info("Initializing TwitchAudio plugin");

    # Register ProtocolHandler
    Slim::Player::ProtocolHandlers->registerHandler(
        twitch => 'Plugins::TwitchAudio::ProtocolHandler'
    );

    $class->SUPER::initPlugin(
        feed   => \&handleFeed,
        tag    => 'twitchaudio',
        menu   => 'radios',
        is_app => 1,
    );
}

# Main menu
sub handleFeed {
    my ($client, $cb, $args) = @_;
    $log->debug("handleFeed called");

    my $items = [
        { name => 'Search channel', type => 'search', url => \&searchChannel },
        { name => 'Favorites', type => 'link', url => \&listFavorites },
    ];

    $cb->({ items => $items });
}

sub searchChannel {
    my ($client, $cb, $args, $search) = @_;
    $log->debug("searchChannel called with query: $search");

    my $items = [
        {
            name => "Play $search",
            type => 'audio',
            url  => "twitch://$search"
        },
        {
            name => "Add to favorites",
            type => 'link',
            url  => sub {
                addFavorite($search);
                $cb->({ items => [{ name => "Saved" }] });
            }
        }
    ];

    $cb->({ items => $items });
}

sub addFavorite {
    my ($channel) = @_;
    my $favs = $prefs->get('favorites') || [];
    push @$favs, $channel unless grep { $_ eq $channel } @$favs;
    $prefs->set('favorites', $favs);
    $log->debug("Favorites updated: " . join(", ", @$favs));
}

sub listFavorites {
    my ($client, $cb, $args) = @_;
    $log->debug("listFavorites called");

    my $favs = $prefs->get('favorites') || [];
    my @items = map { { name => "Play $_", type => 'audio', url => "twitch://$_" } } @$favs;

    $cb->({ items => \@items });
}

1;