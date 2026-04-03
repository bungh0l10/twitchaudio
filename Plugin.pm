package Plugins::TwitchAudio::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Plugins::TwitchAudio::ProtocolHandler;

my $prefs = preferences('plugin.twitchaudio');

my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.twitchaudio',
    defaultLevel => 'INFO',
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

sub handleFeed {
    my ($client, $cb, $args) = @_;

    my $items = [
        {
            name   => 'Search channel',
            type   => 'search',
            url    => \&searchChannel,
            search => 1,
        },
        {
            name => 'Favorites',
            type => 'link',
            url  => \&listFavorites,
        },
    ];

    $cb->({ items => $items });
}

sub searchChannel {
    my ($client, $cb, $args) = @_;

    my $search = $args->{search} || '';
    $search =~ s/^\s+|\s+$//g;

    $log->info("Search query: $search");

    unless ($search) {
        return $cb->({
            items => [{ name => "Enter a channel name" }]
        });
    }

    my $items = [
        {
            name => "▶ Play $search",
            type => 'audio',
            url  => "twitch://$search",
        },
        {
            name => "★ Add to favorites",
            type => 'link',
            url  => sub {
                addFavorite($search);
                $cb->({ items => [{ name => "Saved: $search" }] });
            }
        }
    ];

    $cb->({ items => $items });
}

sub addFavorite {
    my ($channel) = @_;

    return unless $channel;

    my $favs = $prefs->get('favorites') || [];

    unless (grep { $_ eq $channel } @$favs) {
        push @$favs, $channel;
        $prefs->set('favorites', $favs);
    }

    $log->info("Favorites: " . join(", ", @$favs));
}

sub listFavorites {
    my ($client, $cb, $args) = @_;

    my $favs = $prefs->get('favorites') || [];

    my @items = map {
        {
            name => "▶ $_",
            type => 'audio',
            url  => "twitch://$_",
        }
    } @$favs;

    push @items, { name => "No favorites yet" } unless @items;

    $cb->({ items => \@items });
}

1;