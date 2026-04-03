package Plugins::TwitchAudio::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);
use Slim::Player::Song;
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Plugins::TwitchAudio::Twitch;

my $prefs = preferences('plugin.twitchaudio');
my $log   = logger('plugin.twitchaudio');

# Initialize plugin
sub initPlugin {
    my $class = shift;
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
    my $items = [
        { name => 'Search channel', type => 'search', url => \&searchChannel },
        { name => 'Favorites', type => 'link', url => \&listFavorites },
    ];
    $cb->({ items => $items });
}

# Search
sub searchChannel {
    my ($client, $cb, $args, $search) = @_;

    my $items = [
        {
            name => "Play $search",
            type => 'audio',
            url  => sub {
                getTwitchSong($search, $cb);
            }
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

# Add favorite
sub addFavorite {
    my ($channel) = @_;
    my $favs = $prefs->get('favorites') || [];
    push @$favs, $channel unless grep { $_ eq $channel } @$favs;
    $prefs->set('favorites', $favs);
}

# List favorites
sub listFavorites {
    my ($client, $cb, $args) = @_;
    my $favs = $prefs->get('favorites') || [];

    my @items = map {
        {
            name => "Play $_",
            type => 'audio',
            url  => sub { getTwitchSong($_, $cb); }
        }
    } @$favs;

    $cb->({ items => \@items });
}

# Get a real Song from Twitch HLS
sub getTwitchSong {
    my ($channel, $cb) = @_;

    my $url = Plugins::TwitchAudio::Twitch::getAudioUrl($channel);

    my $song = $url
        ? Slim::Player::Song->new({
            title  => "Twitch: $channel",
            url    => $url,
            type   => 'audio',
            plugin => __PACKAGE__,
        })
        : Slim::Player::Song->new({
            title  => "Stream offline: $channel",
            url    => '',  # LMS can skip
            type   => 'audio',
            plugin => __PACKAGE__,
        });

    $cb->({ song => $song });
}

1;