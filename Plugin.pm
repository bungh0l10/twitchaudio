package Plugins::Twitch::Plugin;

use strict;
use warnings;

use parent qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Cache;

use Plugins::Twitch::API;
use Plugins::Twitch::Config ();
use Plugins::Twitch::HLSStream ();

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

    Plugins::Twitch::Config::init();

    $class->SUPER::initPlugin(
        feed   => \&handleFeed,
        tag    => 'twitch',
        menu   => 'radios',
        is_app => 1,
        weight => 1,
    );

    Slim::Player::ProtocolHandlers->registerHandler(
        twitch => 'Plugins::Twitch::ProtocolHandler'
    );

    return;
}

sub handleFeed {
    my ($client, $cb) = @_;

    $cb->({
        items => [ _buildMainMenu($client) ],
    });

    return;
}

sub searchChannel {
    my ($client, $cb, $args) = @_;

    my $query = _normalize_search_query($args->{search});

    return _channelDoesNotExist($client, $cb)
        unless $query;

    Plugins::Twitch::API::getChannel($query, sub {
        my ($data) = @_;

        return _channelDoesNotExist($client, $cb)
            unless $data && $data->{user};

        my $user = $data->{user};
        my $channel = _buildChannelData($user);

        _cache_live_metadata($channel);

        Plugins::Twitch::API::getVods($user->{login}, 1, sub {
            my ($vod_data) = @_;

            my @items = (_buildChannelUiItem($channel));

            for my $vod_type (
                ['Highlights', 'highlights'],
                ['Archive',    'archives'],
            ) {
                my ($title, $type) = @$vod_type;
                next unless @{ _vod_edges($vod_data, $type) };

                push @items, _buildVodMenuItem(
                    $user->{login},
                    $channel,
                    $title,
                    $type,
                );
            }

            $cb->({ items => \@items });

            return;
        });

        return;
    });

    return;
}

sub _vod_edges {
    my ($data, $type) = @_;

    return []
        unless $data
            && $data->{user}
            && $data->{user}{$type}
            && $data->{user}{$type}{edges};

    return $data->{user}{$type}{edges};
}

sub _buildVodMenuItem {
    my ($login, $channel, $title, $type) = @_;

    return {
        name  => $title,
        type  => 'playlist',
        image => $channel->{cover},

        url => sub {
            my ($client, $cb) = @_;

            Plugins::Twitch::API::getVods($login, 100, sub {
                my ($data) = @_;

                my $edges = _vod_edges($data, $type);

                unless (@$edges) {
                    return $cb->({
                        items => [{
                            name => 'No VODs found',
                            type => 'text',
                        }],
                    });
                }

                my @items;

                for my $edge (@$edges) {
                    my $item = _buildVodUiItem($edge);
                    push @items, $item if $item;
                }

                $cb->({ items => \@items });

                return;
            });

            return;
        },
    };
}

sub _buildVodUiItem {
    my ($edge) = @_;

    my $vod = $edge->{node} || return;
    my $vod_id = $vod->{id} || return;
    my $title = $vod->{title} || 'Untitled';
    my $image = $vod->{thumbnailURLs}[0];

    return {
        type     => 'audio',
        name     => $title,
        line1    => $title,
        icon     => $image,
        image    => $image,
        play     => 'twitch:vod:' . $vod_id,
        duration => $vod->{lengthSeconds} || 0,
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

    $cb->({
        items => [{
            name => cstring($client, 'PLUGIN_TWITCH_CHANNEL_DOES_NOT_EXIST'),
            type => 'link',
        }],
    });

    return;
}

sub _buildChannelUiItem {
    my ($channel) = @_;

    return {
        type            => 'audio',
        favorites_type  => 'audio',
        play            => 'twitch:live:' . $channel->{artist},
        line1           => $channel->{artist},
        line2           => $channel->{title},
        image           => $channel->{cover},
        on_select       => 'play',
        duration        => 0,
        title           => $channel->{title},
        favorites_title => $channel->{title},
    };
}

sub _buildChannelData {
    my ($user) = @_;

    my $stream = $user->{stream} // {};

    return {
        artist => lc($user->{login} // ''),
        title  => $stream->{title} // 'Offline',
        cover  => $user->{profileImageURL} // '',
    };
}

sub _cache_live_metadata {
    my ($channel) = @_;

    return unless $channel && $channel->{artist};

    my $cache = Slim::Utils::Cache->new;

    $cache->set(
        "twitch:live:$channel->{artist}",
        {
            title  => $channel->{title},
            artist => $channel->{artist},
            cover  => $channel->{cover},
        },
        Plugins::Twitch::Config::cache_ttl(),
    );

    return;
}

sub _normalize_search_query {
    my ($query) = @_;

    return '' unless defined $query;

    $query =~ s/^\s+|\s+$//g;

    return lc $query;
}

1;
