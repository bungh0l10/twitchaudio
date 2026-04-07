package Plugins::Twitch::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string  cstring);
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
        { name => cstring($client, 'PLUGIN_TWITCH_SEARCH'), type => 'search', url => \&searchChannel },
    ];

    $cb->({ items => $items });
}

# Search channel and fetch info
sub searchChannel {
    my ($client, $cb, $args) = @_;

    my $search = $args->{search} || '';
    $search =~ s/^\s+|\s+$//g;
    $search = lc $search;

    $log->info("Search query: $search");

    # API-Aufruf zum Twitch-Kanal
    Plugins::Twitch::API::getChannel($search, sub {
        my ($data) = @_;
        my $user = $data->{user} // undef;

        # Kanal existiert nicht
        unless ($user) {
            return $cb->({
                items => [{
                    name => cstring($client, 'PLUGIN_TWITCH_CHANNEL_DOES_NOT_EXIST'),
                    type => 'link',
                }]
            });
        }

        # Kanalstatus
        my $stream = $user->{stream} // undef;
        my $title  = $stream ? $stream->{title} : 'Offline';
        my $cover  = $user->{profileImageURL} || '';
        my $artist = $user->{login};

        # Stream/Audio-URL (wenn online)
        my $url = $stream ? Plugins::Twitch::API::getAudioUrl($artist) : undef;

        # OPML-Item für LMS
        my $items = [
            {
                name        => $artist,       # Kanalname in Liste
                type        => 'audio',       # Player weiß, dass Audio kommt
                favorites_type => 'audio',
                play        => $url,          # URL zum Abspielen
                on_select   => 'play',
                image       => $cover,        # Cover wird in Playlist angezeigt
                artist      => $artist,       # Player zeigt Interpret
                title       => $title,        # Player zeigt Titel
                description => $title,        # Hover/Tooltip
                line1       => $title,        # Playlist Zeile 1
                line2       => $artist,       # Playlist Zeile 2
                duration    => 0,             # optional, wenn unbekannt
            }
        ];

        $cb->({ items => $items });
    });
}

1;