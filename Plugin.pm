package Plugins::Twitch::Plugin;

use strict;
use warnings;

use parent qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::Twitch::API;

use constant {
    VOD_LIMIT => 100,
};

my $prefs = preferences('plugin.twitch');

my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.twitch',
    defaultLevel => 'INFO',
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
        is_app => 1,
        menu   => 'radios',
        tag    => 'twitch',
        weight => 1,
    );

    Slim::Player::ProtocolHandlers->registerHandler(
        twitch => 'Plugins::Twitch::ProtocolHandler'
    );

    return 1;
}

sub handleFeed {
    my ($client, $cb, $args) = @_;

    return $cb->({
        items => [ _buildMainMenu($client) ],
    });
}

sub searchChannel {
    my ($client, $cb, $args) = @_;

    my $query = _normalizeSearchQuery($args->{search});

    return _channelDoesNotExist($client, $cb)
        unless $query;

    return Plugins::Twitch::API::getChannel($query, sub {
        my ($data) = @_;

        return _channelDoesNotExist($client, $cb)
            unless $data && $data->{user};

        my $user    = $data->{user};
        my $channel = _buildChannelData($user);

        return Plugins::Twitch::API::getVods($user->{login}, 1, sub {
            my ($vod_data) = @_;

            my $edges = _extractVodEdges($vod_data);

            my @items = (
                _buildChannelUiItem($channel),
            );

            if (@{$edges}) {
                push @items, _buildVodMenuItem(
                    $user->{login},
                    $user->{profileImageURL}
                );
            }

            return $cb->({ items => \@items });
        });
    });
}

sub _extractVodEdges {
    my ($vod_data) = @_;

    return []
        unless $vod_data
            && $vod_data->{user}
            && $vod_data->{user}{videos}
            && $vod_data->{user}{videos}{edges};

    return $vod_data->{user}{videos}{edges} || [];
}

sub _buildVodMenuItem {
    my ($login, $cover) = @_;

    my $url_cb = sub {
        my ($client, $cb) = @_;

        return Plugins::Twitch::API::getVods($login, VOD_LIMIT, sub {
            my ($data) = @_;

            my $edges = _extractVodEdges($data);

            return $cb->({
                items => [{
                    name => 'No VODs found',
                    type => 'text',
                }]
            }) unless @{$edges};

            my @items;

            foreach my $edge (@{$edges}) {
                my $v = $edge->{node} || next;

                next unless $v->{id};

                my $thumb = $v->{thumbnailURLs}
                    ? $v->{thumbnailURLs}[0]
                    : '';

                push @items, {
                    duration => $v->{lengthSeconds} || 0,
                    icon     => $thumb,
                    image    => $thumb,
                    line1    => $v->{title} || 'Untitled',
                    name     => $v->{title} || 'Untitled',
                    play     => 'twitch:vod:' . $v->{id},
                    type     => 'audio',
                };
            }

            return $cb->({ items => \@items });
        });
    };

    return {
        icon  => $cover,
        image => $cover,
        name  => 'VODs',
        type  => 'playlist',
        url   => $url_cb,
    };
}

sub _buildMainMenu {
    my ($client) = @_;

    return {
        name => cstring($client, 'PLUGIN_TWITCH_SEARCH'),
        type => 'search',
        url  => \&searchChannel,
    };
}

sub _channelDoesNotExist {
    my ($client, $cb) = @_;

    return $cb->({
        items => [{
            name => cstring($client, 'PLUGIN_TWITCH_CHANNEL_DOES_NOT_EXIST'),
            type => 'link',
        }]
    });
}

sub _buildChannelUiItem {
    my ($channel) = @_;

    return {
        duration        => 0,
        favorites_type  => 'audio',
        favorites_title => $channel->{title},
        image           => $channel->{cover},
        line1           => $channel->{artist},
        line2           => $channel->{title},
        on_select       => 'play',
        play            => 'twitch:live:' . $channel->{artist},
        title           => $channel->{title},
        type            => 'audio',
    };
}

sub _buildChannelData {
    my ($user) = @_;

    my $stream = $user->{stream} || {};

    return {
        artist => lc($user->{login} || ''),
        cover  => $user->{profileImageURL} || '',
        title  => $stream->{title} || 'Offline',
    };
}

sub _normalizeSearchQuery {
    my ($query) = @_;

    return '' unless defined $query;

    $query =~ s/^\s+|\s+$//g;

    return lc $query;
}

1;