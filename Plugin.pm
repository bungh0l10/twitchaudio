package Plugins::Twitch::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Cache;

use Plugins::Twitch::API;

my $prefs = preferences('plugin.twitch');

my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.twitch',
    defaultLevel => 'DEBUG',
    description  => 'PLUGIN_TWITCH_DESCRIPTION',
    logGroups    => 'SCANNER',
});

sub getDisplayName {
    return 'PLUGIN_TWITCH_NAME';
}

sub initPlugin {
    my ($class) = @_;

    $class->SUPER::initPlugin(
        feed   => \&handleFeed,
        tag    => 'twitch',
        menu   => 'radios',
        is_app => 1,
        weight => 1
    );

    Slim::Player::ProtocolHandlers->registerHandler(
        twitch => 'Plugins::Twitch::ProtocolHandler'
    );

    return;
}

sub handleFeed {
    my ($client, $cb, $args) = @_;

    my $items = _buildRootItems($client);

    $cb->({ items => $items });

    return;
}

sub searchChannel {
    my ($client, $cb, $args) = @_;

    my $query = _normalizeQuery($args->{search});

    Plugins::Twitch::API::getChannel($query, sub {
        my ($data) = @_;

        return _handleNoUser($client, $cb)
            unless $data && $data->{user};

        my $item = _buildChannelItem($data->{user});

        _cacheMetadata($item->{artist}, $item);

        $cb->({ items => [$item] });

        return;
    });

    return;
}

sub _buildRootItems {
    my ($client) = @_;

    return [
        {
            name => cstring($client, 'PLUGIN_TWITCH_SEARCH'),
            type => 'search',
            url  => \&searchChannel
        }
    ];
}

sub _handleNoUser {
    my ($client, $cb) = @_;

    $cb->({
        items => [{
            name => cstring($client, 'PLUGIN_TWITCH_CHANNEL_DOES_NOT_EXIST'),
            type => 'link',
        }]
    });

    return;
}

sub _buildChannelItem {
    my ($user) = @_;

    my $stream = $user->{stream} || {};

    my $artist = lc($user->{login} || '');
    my $title  = $stream->{title} || 'Offline';
    my $cover  = $user->{profileImageURL} || '';

    return {
        type           => 'audio',
        favorites_type => 'audio',
        play           => 'twitch://' . $artist,
        name           => $artist,
        line1          => $artist,
        line2          => $title,
        image          => $cover,
        on_select      => 'play',
        duration       => 0,
        artist         => $artist,
    };
}

sub _cacheMetadata {
    my ($artist, $item) = @_;

    return unless $artist;

    my $cache = Slim::Utils::Cache->new;

    $cache->set(
        "twitch_meta_$artist",
        {
            title  => $item->{line2},
            artist => $artist,
            cover  => $item->{image},
        },
        60
    );

    return;
}

sub _normalizeQuery {
    my ($query) = @_;

    return '' unless defined $query;

    $query =~ s/^\s+|\s+$//g;
    return lc $query;
}

1;