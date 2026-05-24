package Plugins::Twitch::Plugin;

use strict;
use warnings;

use parent qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Cache;

use Plugins::Twitch::API;

use constant {
    PLAYBACK_CACHE_TTL => 3600,
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
    my ($client, $cb, $args) = @_;

    $cb->({
        items => [ _buildMainMenu($client) ],
    });

    return;
}

sub searchChannel {
    my ($client, $cb, $args) = @_;

    my $query = _normalizeSearchQuery($args->{search});

    return _channelDoesNotExist($client, $cb)
        unless $query;

    Plugins::Twitch::API::getChannel($query, sub {
        my ($data) = @_;

        return _channelDoesNotExist($client, $cb)
            unless $data && $data->{user};

        my $user    = $data->{user};
        my $channel = _buildChannelData($user);

        Plugins::Twitch::API::getVods($user->{login}, 1, sub {
            my ($vod_data) = @_;

            my $highlights =
                   $vod_data
                && $vod_data->{user}
                && $vod_data->{user}{highlights}
                && $vod_data->{user}{highlights}{edges}
                || [];

            my $archives =
                   $vod_data
                && $vod_data->{user}
                && $vod_data->{user}{archives}
                && $vod_data->{user}{archives}{edges}
                || [];

            my @items = (
                _buildChannelUiItem($channel),
            );

            if (@$highlights) {
                push @items, _buildVodMenuItem($user->{login}, $channel, 'Highlights', 'highlights');
            }

            if (@$archives) {
                push @items, _buildVodMenuItem($user->{login}, $channel, 'Archive', 'archives');
            }

            $cb->({ items => \@items });

            return;
        });

        return;
    });

    return;
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

                my $edges =
                       $data
                    && $data->{user}
                    && $data->{user}{$type}
                    && $data->{user}{$type}{edges}
                    || [];

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
                    my $v = $edge->{node} || next;
                    my $vod_id = $v->{id} || next;

                    push @items, {
                        type  => 'audio',
                        name  => $v->{title} || 'Untitled',
                        line1 => $v->{title} || 'Untitled',
                        icon  => $v->{thumbnailURLs}[0],
                        image => $v->{thumbnailURLs}[0],
                        play  => 'twitch:vod:' . $vod_id,
                        duration => $v->{lengthSeconds} || 0,
                    };
                }

                $cb->({ items => \@items });

                return;
            });

            return;
        },
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

sub _cachePlayback {
    my ($channel) = @_;

    return unless $channel && $channel->{name};

    my $cache = Slim::Utils::Cache->new;

    $cache->set(
        "twitch_playback_$channel->{name}",
        $channel,
        PLAYBACK_CACHE_TTL,
    );

    return;
}

sub _normalizeSearchQuery {
    my ($query) = @_;

    return '' unless defined $query;

    $query =~ s/^\s+|\s+$//g;

    return lc $query;
}

1;