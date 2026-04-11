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

sub handleFeed {
    my ($client, $cb, $args) = @_;
    $log->debug("handleFeed called");

    my $items = [
        { name => cstring($client, 'PLUGIN_TWITCH_SEARCH'), type => 'search', url => \&searchChannel },
    ];

    $cb->({ items => $items });
}

sub searchChannel {
    my ($client, $cb, $args) = @_;

    my $search = $args->{search} || '';
    $search =~ s/^\s+|\s+$//g;
    $search = lc $search;

    $log->info("Search query: $search");

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

        my $stream = $user->{stream} // undef;
        my $title  = $stream ? $stream->{title} : 'Offline';
        my $cover  = $user->{profileImageURL} || '';
        my $artist = $user->{login};

        my $url = $stream ? Plugins::Twitch::API::getAudioUrl($artist) : undef;

        my $items = [
            {
                type           => 'audio',
                favorites_type => 'audio',
                play           => 'twitch://' . $artist,
                name           => $artist,
                line1          => $artist,
                line2          => $title,
                image          => $cover,
                on_select      => 'play',
                duration       => 0,
            }
        ];

        $cb->({ items => $items });
    });
}

1;