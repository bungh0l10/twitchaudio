package Plugins::TwitchAudio::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Plugins::TwitchAudio::Twitch;

my $prefs = preferences('plugin.twitchaudio');
my $log   = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.twitchaudio',
    defaultLevel => 'WARN',
    description  => 'Twitch Audio Plugin',
});

sub initPlugin {
    my $class = shift;

    Slim::Player::ProtocolHandlers->registerHandler(
        twitch => 'Plugins::TwitchAudio::ProtocolHandler'
    );

    $class->SUPER::initPlugin(
        feed   => \&handleFeed,
        tag    => 'twitchaudio',
        menu   => 'radios',
        is_app => 1,
    );

    $log->info("Plugin initialized");
}

# --- Main menu ---
sub handleFeed {
    my ($client, $cb, $args) = @_;

    $log->debug("handleFeed called");

    my $items = [
        {
            name => 'Search Channel',
            type => 'search',
            url  => \&searchChannel,
        },
        {
            name => 'Favorites',
            type => 'link',
            url  => \&listFavorites,
        },
    ];

    $cb->({ items => $items });
}

# --- Search ---
sub searchChannel {
    my ($client, $cb, $args, $search) = @_;
    $search ||= '';
    $search =~ s/^\s+|\s+$//g;  # trim spaces

    $log->debug("searchChannel called with query: '$search'");

    return $cb->({ items => [] }) unless $search;

    $cb->({
        items => [
            {
                name => "Play $search",
                type => 'audio',
                url  => "twitch://$search",
            },
            {
                name => "Add to Favorites",
                type => 'link',
                url  => sub {
                    addFavorite($search);
                    $cb->({ items => [{ name => "Saved ✔" }] });
                }
            }
        ]
    });
}

# --- Favorites management ---
sub addFavorite {
    my ($channel) = @_;
    my $favs = $prefs->get('favorites') || [];

    push @$favs, $channel unless grep { $_ eq $channel } @$favs;
    $prefs->set('favorites', $favs);

    $log->info("Favorites updated: " . join(',', @$favs));
}

sub listFavorites {
    my ($client, $cb, $args) = @_;
    my $favs = $prefs->get('favorites') || [];

    my @items = map {
        {
            name => "Play $_",
            type => 'audio',
            url  => "twitch://$_",
        }
    } @$favs;

    $cb->({ items => \@items });
}

# --- ProtocolHandler check ---
sub canHandle {
    my ($class, $url) = @_;
    return $url =~ /^twitch:/;
}

sub getNextTrack {
    my ($class, $client, $cb, $args) = @_;

    my ($channel) = $args->{url} =~ m{^twitch://(.+)$};
    return $cb->({ error => "Invalid channel" }) unless $channel;

    $log->debug("Fetching audio for channel: $channel");

    my $stream = Plugins::TwitchAudio::Twitch::getAudioUrl($channel);

    if ($stream) {
        $cb->({ url => $stream });
    } else {
        $cb->({ error => "Stream offline or unavailable" });
        $log->warn("No stream returned for channel: $channel");
    }
}

1;