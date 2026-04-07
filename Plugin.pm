package Plugins::Twitch::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Plugins::Twitch::API;

my $prefs = preferences('plugin.twitch');

my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.twitch',
    defaultLevel => 'DEBUG',
    description  => 'PLUGIN_TWITCH_DESCRIPTION',
    logGroups    => 'SCANNER',
});

sub getDisplayName {
    return 'PLUGIN_TWITCH_NAME'
}

sub initPlugin {
    my $class = shift;
    $log->debug("Initializing Twitch plugin");

    $class->SUPER::initPlugin(
        feed   => \&handleFeed,
        tag    => 'twitch',
        menu   => 'radios',
        is_app => 1,
        weight  => 1
    );

    Slim::Player::ProtocolHandlers->registerHandler(
        twitch => 'Plugins::Twitch::ProtocolHandler'
    );
}

# Main menu
sub handleFeed {
    my ($client, $cb, $args) = @_;
    $log->debug("handleFeed called");

    my $items = [
        { name => 'PLUGIN_TWITCH_SEARCH', type => 'search', url => \&searchChannel },
    ];

    $cb->({ items => $items });
}

# Search channel and fetch info
sub searchChannel {
    my ($client, $cb, $args) = @_;
    my $search = $args->{search} || '';
    $search =~ s/^\s+|\s+$//g;
    $search = lc $search;

    return $cb->({ items => [{ name => "Enter a channel name" }] }) unless $search;

    $log->info("Search query: $search");

    Plugins::Twitch::Twitch::getChannel($search, sub {
        my ($data) = @_;
        my $user   = $data->{user} if $data;
        my $online = $user && $user->{stream} ? 1 : 0;

        # Twitch-Daten
        my $title  = $online ? $user->{stream}{title} : "Offline";
        my $cover  = $user ? $user->{profileImageURL} : "";
        my $artist = $user ? $user->{login} : $search;  # echter Kanalname als Artist

        my $url;
        if ($online) {
            $url = Plugins::Twitch::API::getAudioUrl($artist);
        }

        my $items = [
            {
                name   => $artist,       # Anzeigename in der Liste
                type   => $online ? 'audio' : 'link',
                url    => $url || "twitch://$artist",
                artist => $artist,       # Player zeigt Interpret
                title  => $title,        # Player zeigt Titel
                cover  => $cover,        # Player zeigt Cover
                image  => $cover,
                description => $title

            }
        ];

        $cb->({ items => $items });
    });
}

1;