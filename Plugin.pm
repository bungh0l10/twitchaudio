package Plugins::TwitchAudio::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);
use Slim::Player::ProtocolHandlers;
use Slim::Player::Song;
use Slim::Utils::Prefs;
use Plugins::TwitchAudio::Twitch;

my $prefs = preferences('plugin.twitchaudio');

# --- Plugin initialization ---
sub initPlugin {
    my $class = shift;

    # Register Twitch protocol handler
    Slim::Player::ProtocolHandlers->registerHandler(
        twitch => $class
    );

    # Initialize OPML-based plugin
    $class->SUPER::initPlugin(
        feed   => \&handleFeed,
        tag    => 'twitchaudio',
        menu   => 'radios',
        is_app => 1,
    );
}

# --- Main menu ---
sub handleFeed {
    my ($client, $cb, $args) = @_;

    my $items = [
        {
            name => 'Search channel',
            type => 'search',
            url  => \&searchChannel,
        },
        {
            name => 'Favorites',
            type => 'link',
            url  => \&listFavorites,
        }
    ];

    $cb->({ items => $items });
}

# --- Search channels ---
sub searchChannel {
    my ($client, $cb, $args, $search) = @_;

    # Playable Song object
    my $song = Slim::Player::Song->new({
        title  => "Play $search",
        url    => "twitch://$search",
        type   => 'audio',
        plugin => __PACKAGE__,
    });

    my $items = [
        $song,
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

# --- Favorites storage ---
sub addFavorite {
    my ($channel) = @_;
    my $favs = $prefs->get('favorites') || [];
    push @$favs, $channel unless grep { $_ eq $channel } @$favs;
    $prefs->set('favorites', $favs);
}

# --- List favorites ---
sub listFavorites {
    my ($client, $cb, $args) = @_;
    my $favs = $prefs->get('favorites') || [];

    my @items = map {
        Slim::Player::Song->new({
            title  => "Play $_",
            url    => "twitch://$_",
            type   => 'audio',
            plugin => __PACKAGE__,
        })
    } @$favs;

    $cb->({ items => \@items });
}

# --- Protocol handler ---
sub canHandle {
    my ($class, $url) = @_;
    return $url =~ /^twitch:/;
}

sub getNextTrack {
    my ($class, $client, $cb, $args) = @_;

    my ($channel) = $args->{url} =~ m{^twitch://(.+)$};

    my $stream;
    my $tries = 3;

    while ($tries--) {
        $stream = Plugins::TwitchAudio::Twitch::getAudioUrl($channel);
        last if $stream;
        sleep 2;
    }

    if ($stream) {
        my $song = Slim::Player::Song->new({
            title  => "Twitch: $channel",
            url    => $stream,
            type   => 'audio',
            plugin => $class,
        });
        $cb->({ song => $song });
    } else {
        $cb->({ error => "Stream offline or not available" });
    }
}

1;