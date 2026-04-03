package Plugins::TwitchAudio::Plugin;

use strict;
use warnings;
use JSON::PP;
use URI::Escape qw(uri_escape);
use Slim::Utils::Log;
use Plugins::TwitchAudio::Twitch;

# Set up logging category
my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.twitchaudio',
    defaultLevel => 'WARN',
    description  => 'PLUGIN_TWITCHAUDIO',
    logGroups    => 'SCANNER',
});

# Called by LMS to show the main menu
sub handleFeed {
    my ($class, $client, $cb, $args) = @_;
    $log->debug("handleFeed called; args: " . encode_json($args));

    my $items = [
        { name => "Search Channel", type => 'search', searchHandler => \&searchChannel },
        { name => "Favorites", type => 'link', url => sub { showFavorites($client, $cb) } },
    ];

    $cb->({ items => $items });
}

# Called when LMS searches for a channel
sub searchChannel {
    my ($client, $cb, $args, $search) = @_;
    $search ||= '';
    $search =~ s/^\s+|\s+$//g;

    $log->debug("searchChannel called; args: " . encode_json($args) . ", query: '$search'");

    # Avoid empty searches
    return $cb->({ items => [] }) unless $search;

    # Attempt to fetch audio URL
    my $url = Plugins::TwitchAudio::Twitch::getAudioUrl($search);

    if ($url) {
        $log->debug("Found audio URL for '$search': $url");
    } else {
        $log->warn("No audio URL found for '$search'");
    }

    $cb->({
        items => [
            { name => "Play $search", type => 'audio', url => $url || "twitch://$search" },
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

# Simple favorite handling
my @favorites;
sub addFavorite {
    my ($channel) = @_;
    push @favorites, $channel unless grep { $_ eq $channel } @favorites;
    $log->debug("Favorites updated: " . join(", ", @favorites));
}

sub showFavorites {
    my ($client, $cb) = @_;
    my @items = map { { name => $_, type => 'audio', url => "twitch://$_" } } @favorites;
    $cb->({ items => \@items });
}

1;