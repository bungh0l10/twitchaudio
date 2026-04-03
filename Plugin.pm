package Plugins::TwitchAudio::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);
use Slim::Utils::Prefs;
use Plugins::TwitchAudio::Twitch;

my $prefs = preferences('plugin.twitchaudio');

sub initPlugin {
    my $class = shift;

    Slim::Player::ProtocolHandlers->registerHandler(
        twitch => 'Plugins::TwitchAudio::Plugin'
    );

    $class->SUPER::initPlugin(
        feed   => \&handleFeed,
        tag    => 'twitchaudio',
        menu   => 'radios',
        is_app => 1,
    );
}

# --- Hauptmenü ---
sub handleFeed {
    my ($client, $cb, $args) = @_;

    my $items = [
        {
            name => '🔎 Channel suchen',
            type => 'search',
            url  => \&searchChannel,
        },
        {
            name => '⭐ Favoriten',
            type => 'link',
            url  => \&listFavorites,
        }
    ];

    $cb->({ items => $items });
}

# --- Suche ---
sub searchChannel {
    my ($client, $cb, $args, $search) = @_;

    $cb->({
        items => [
            {
                name => "▶ $search",
                type => 'audio',
                url  => "twitch://$search",
            },
            {
                name => "⭐ Zu Favoriten hinzufügen",
                type => 'link',
                url  => sub {
                    addFavorite($search);
                    $cb->({ items => [{ name => "Gespeichert ✔" }] });
                }
            }
        ]
    });
}

# --- Favoriten speichern ---
sub addFavorite {
    my ($channel) = @_;
    my $favs = $prefs->get('favorites') || [];

    push @$favs, $channel unless grep { $_ eq $channel } @$favs;
    $prefs->set('favorites', $favs);
}

# --- Favoriten anzeigen ---
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

    $cb->({ items => \@items });
}

# --- Handler ---
sub canHandle {
    my ($class, $url) = @_;
    return $url =~ /^twitch:/;
}

sub getNextTrack {
    my ($class, $client, $cb, $args) = @_;

    my ($channel) = $args->{url} =~ m{^twitch://(.+)$};

    my $tries = 3;
    my $stream;

    while ($tries--) {
        $stream = Plugins::TwitchAudio::Twitch::getAudioUrl($channel);
        last if $stream;

        sleep 2; # Retry delay
    }

    if ($stream) {
        $cb->({
            url => $stream,
        });
    } else {
        $cb->({
            error => "Stream offline oder nicht verfügbar",
        });
    }
}

1;