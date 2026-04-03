package Plugins::TwitchAudio::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Plugins::TwitchAudio::Twitch;
use Plugins::TwitchAudio::ProtocolHandler;

my $prefs = preferences('plugin.twitchaudio');

my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.twitchaudio',
    defaultLevel => 'DEBUG',
    description  => 'TwitchAudio Plugin',
    logGroups    => 'SCANNER',
});

sub initPlugin {
    my $class = shift;
    $log->info("Initializing TwitchAudio plugin");

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

# Search channel and fetch info
sub searchChannel {
    my ($client, $cb, $args) = @_;
    my $search = $args->{search} || '';
    $search =~ s/^\s+|\s+$//g;

    return $cb->({ items => [{ name => "Enter a channel name" }] }) unless $search;

    $log->info("Search query: $search");

    Plugins::TwitchAudio::Twitch::getChannel($search, sub {
        my ($data) = @_;
        my $user = $data->{user} if $data;
        my $online = $user && $user->{stream} ? 1 : 0;
        my $title  = $online ? $user->{stream}{title} : "Offline";
        my $cover  = $user ? $user->{profileImageURL} : "";

        my $url;
        if ($online) {
            $url = Plugins::TwitchAudio::Twitch::getAudioUrl($search);
        }

        my $items = [
            {
                name  => $search,
                type  => $online ? 'audio' : 'link',
                url   => $url || "twitch://$search",
                title => $title,
                cover => $cover,
            },
            {
                name => "Add to favorites",
                type => 'link',
                url  => sub {
                    addFavorite($search);
                    $cb->({ items => [{ name => "Saved: $search" }] });
                }
            }
        ];

        $cb->({ items => $items });
    });
}

# Favorites
sub addFavorite {
    my ($channel) = @_;
    my $favs = $prefs->get('favorites') || [];
    push @$favs, $channel unless grep { $_ eq $channel } @$favs;
    $prefs->set('favorites', $favs);
    $log->debug("Favorites updated: " . join(", ", @$favs));
}

sub listFavorites {
    my ($client, $cb, $args) = @_;
    my $favs = $prefs->get('favorites') || [];
    my @items = map {
        {
            name  => $_,
            type  => 'audio',
            url   => "twitch://$_",
        }
    } @$favs;

    $cb->({ items => \@items });
}

1;