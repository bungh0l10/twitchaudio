package Plugins::Twitch::Plugin;

use strict;
use warnings;

use parent qw(Slim::Plugin::OPMLBased);

use Slim::Control::Request ();
use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring string);
use Slim::Utils::Cache;

use Plugins::Twitch::API;
use Plugins::Twitch::Config ();
use Plugins::Twitch::HLSStream ();

my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.twitch',
    defaultLevel => 'ERROR',
    description  => 'PLUGIN_TWITCH_DESCRIPTION',
    logGroups    => 'SCANNER',
});

my $material_actions_registered;
my $channel_commands_registered;

sub getDisplayName {
    return 'PLUGIN_TWITCH_NAME';
}

sub _register_protocol_handlers {
    Slim::Player::ProtocolHandlers->registerHandler(
        twitch => 'Plugins::Twitch::ProtocolHandler'
    );
    Slim::Player::ProtocolHandlers->registerHandler(
        twitchhls => 'Plugins::Twitch::HLSStream'
    );
    return;
}

sub _register_material_actions {
    return if $material_actions_registered;

    my $register = Plugins::MaterialSkin::Plugin->can(
        'registerCustomAction'
    );
    return unless $register;

    my @actions = ({
        title  => string('PLUGIN_TWITCH_OPEN_ON_TWITCH'),
        icon   => 'open_in_new',
        filter => 'twitch:',
        script => <<'JAVASCRIPT',
var twitchUrl = "$FAVURL";
var twitchParts = twitchUrl.match(
    /^twitch:(live(?:-(?:saved|unsaved))?|vod):([a-z0-9_]+)$/
);
if (twitchParts) {
    window.open(
        "https://www.twitch.tv/"
            + (twitchParts[1] === "vod" ? "videos/" : "")
            + encodeURIComponent(twitchParts[2])
    );
}
JAVASCRIPT
    }, {
        title      => string('PLUGIN_TWITCH_ADD_TO_MY_CHANNELS'),
        icon       => 'playlist_add',
        filter     => 'twitch:live-unsaved:',
        lmscommand => [
            'twitch', 'channels', 'add', 'url:$FAVURL',
        ],
    }, {
        title      => string('PLUGIN_TWITCH_REMOVE_FROM_MY_CHANNELS'),
        icon       => 'playlist_remove',
        filter     => 'twitch:live-saved:',
        lmscommand => [
            'twitch', 'channels', 'remove', 'url:$FAVURL',
        ],
    });

    # Material currently represents generic playable app entries as albums.
    # Register the track category too so the action remains available if the
    # item carries richer online-track metadata now or in a future LMS release.
    for my $section (qw(twitch-album twitch-track)) {
        for my $action (@actions) {
            $register->($section, { %$action });
        }
    }

    $material_actions_registered = 1;
    return;
}

sub _saved_channel_command {
    my ($request) = @_;

    my $method = $request->getParam('_method') // '';
    my $url = $request->getParam('url') // '';
    my ($state, $login) = $url =~
        /^twitch:live-(saved|unsaved):([a-z0-9_]{4,25})$/;

    my $valid_transition = (
        $method eq 'add' && ($state // '') eq 'unsaved'
    ) || (
        $method eq 'remove' && ($state // '') eq 'saved'
    );

    unless ($login && $valid_transition) {
        $request->setStatusBadParams();
        return;
    }

    my $changed = $method eq 'add'
        ? Plugins::Twitch::Config::add_saved_channel($login)
        : Plugins::Twitch::Config::remove_saved_channel($login);

    $request->addResult('changed', $changed ? 1 : 0);
    $request->addResult(
        'count',
        scalar @{ Plugins::Twitch::Config::saved_channels() },
    );
    $request->setStatusDone();

    return;
}

sub _register_channel_commands {
    return if $channel_commands_registered;

    Slim::Control::Request::addDispatch(
        ['twitch', 'channels', '_method'],
        [0, 0, 1, \&_saved_channel_command],
    );

    $channel_commands_registered = 1;
    return;
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

    _register_channel_commands();
    _register_protocol_handlers();

    return;
}

# Re-assert both handlers after every plugin has completed its normal
# initialization. This avoids a later initPlugin replacing a registration made
# by Twitch earlier in the alphabetically ordered startup pass.
sub postinitPlugin {
    _register_protocol_handlers();
    _register_material_actions();
    return;
}

sub handleFeed {
    my ($client, $cb) = @_;

    $cb->({
        items => [
            _buildMainMenu($client),
            _buildSavedChannelsMenu($client),
        ],
    });

    return;
}

sub searchChannel {
    my ($client, $cb, $args) = @_;

    my $query = _normalize_search_query($args->{search});

    return _channelDoesNotExist($client, $cb)
        unless $query;

    my ($vod_id, $is_explicit_vod) = _vod_id_from_search($query);
    if ($vod_id) {
        Plugins::Twitch::API::getVodMeta($vod_id, sub {
            my ($vod, $api_error) = @_;

            if ($vod) {
                my @items = (_buildVodMetaUiItem($vod));
                push @items, _twitchServiceImpactUiItem($client)
                    if $api_error;

                return $cb->({
                    items => \@items,
                });
            }

            return _twitchServiceImpact($client, $cb)
                if $api_error;

            return _vodDoesNotExist($client, $cb)
                if $is_explicit_vod;

            return _searchChannelLogin($client, $cb, $query);
        });

        return;
    }

    return _channelDoesNotExist($client, $cb)
        unless _is_channel_login($query);

    return _searchChannelLogin($client, $cb, $query);
}

sub _searchChannelLogin {
    my ($client, $cb, $query, $context) = @_;

    Plugins::Twitch::API::getChannel($query, sub {
        my ($data, $api_error) = @_;

        return _twitchServiceImpact($client, $cb)
            if $api_error && (!$data || !$data->{user});

        return _channelDoesNotExist($client, $cb)
            unless $data && $data->{user};

        my $user = $data->{user};
        my $channel = _buildChannelData($client, $user);

        _cache_live_metadata($channel);

        Plugins::Twitch::API::getVods($user->{login}, 1, sub {
            my ($vod_data, $vod_error) = @_;

            my @items = (_buildChannelUiItem($channel, $context));

            push @items, _twitchServiceImpactUiItem($client)
                if $vod_error;

            for my $vod_type (
                ['PLUGIN_TWITCH_HIGHLIGHTS', 'highlights'],
                ['PLUGIN_TWITCH_ARCHIVE',    'archives'],
            ) {
                my ($title_key, $type) = @$vod_type;
                next unless @{ _vod_edges($vod_data, $type) };

                push @items, _buildVodMenuItem(
                    $user->{login},
                    $channel,
                    cstring($client, $title_key),
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

sub _vod_id_from_search {
    my ($query) = @_;
    return unless defined $query;

    return ($1, 1) if $query =~ /^twitch:vod:(\d{1,20})$/;
    return ($1, 1) if $query =~ m{
        ^(?:https?://)?(?:www\.)?twitch\.tv/videos/(\d{1,20})
        (?:[/?#][a-z0-9_~.!\$&'()*+,;=:\@%/?#-]*)?$
    }ix;
    return ($query, 0) if $query =~ /^\d{1,20}$/;
    return;
}

sub _is_channel_login {
    my ($query) = @_;
    return defined $query && $query =~ /^[a-z0-9_]{4,25}$/ ? 1 : 0;
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
        type  => 'link',
        icon  => $channel->{cover},
        image => $channel->{cover},

        url => sub {
            my ($client, $cb) = @_;

            Plugins::Twitch::API::getVods($login, 100, sub {
                my ($data, $api_error) = @_;

                my $edges = _vod_edges($data, $type);

                unless (@$edges) {
                    return _twitchServiceImpact($client, $cb)
                        if $api_error;
                    return $cb->({ items => [] });
                }

                my @items;

                push @items, _twitchServiceImpactUiItem($client)
                    if $api_error;

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
    my $title = $vod->{title} || return;
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

sub _buildVodMetaUiItem {
    my ($vod) = @_;

    return _buildVodUiItem({
        node => {
            id            => $vod->{id},
            title         => $vod->{title},
            lengthSeconds => $vod->{duration},
            thumbnailURLs => [$vod->{thumbnail}],
        },
    });
}

sub _buildMainMenu {
    my ($client) = @_;

    return {
        name => cstring($client, 'PLUGIN_TWITCH_SEARCH'),
        type => 'search',
        url  => \&searchChannel,
    };
}

sub _buildSavedChannelsMenu {
    my ($client) = @_;

    return {
        name => cstring($client, 'PLUGIN_TWITCH_MY_CHANNELS'),
        type => 'link',
        url  => sub {
            my ($client, $cb) = @_;
            my @channels = @{ Plugins::Twitch::Config::saved_channels() };

            unless (@channels) {
                return $cb->({
                    items => [{
                        name => cstring(
                            $client,
                            'PLUGIN_TWITCH_NO_SAVED_CHANNELS',
                        ),
                        type => 'text',
                    }],
                });
            }

            return _loadSavedChannelItems($client, \@channels, $cb);
        },
    };
}

sub _buildSavedChannelMenuItem {
    my ($login, $cover) = @_;

    # Material suppresses child artwork when it has the exact same URL as the
    # parent artwork. Keep the same Twitch image but give the saved-list row a
    # stable URL variant so Live, Highlights and Archive retain their images.
    my $saved_cover = $cover;
    if (defined $saved_cover && length $saved_cover) {
        $saved_cover .= $saved_cover =~ /\?/ ? '&twitchaudio=saved'
            : '?twitchaudio=saved';
    }

    my $item = {
        name          => $login,
        type          => 'playlist',
        play          => 'twitch:live:' . $login,
        favorites_url => 'twitch:live-saved:' . $login,
        url => sub {
            my ($client, $cb) = @_;
            return _searchChannelLogin(
                $client,
                $cb,
                $login,
                'saved_channel',
            );
        },
    };

    if (defined $saved_cover && length $saved_cover) {
        $item->{icon} = $saved_cover;
        $item->{image} = $saved_cover;
    }

    return $item;
}

sub _loadSavedChannelItems {
    my ($client, $channels, $cb) = @_;

    my @items;
    my $pending = scalar @$channels;
    my $cache = Slim::Utils::Cache->new;

    for my $index (0 .. $#$channels) {
        my $item_index = $index;
        my $login = $channels->[$index];
        my $cached = $cache->get("twitch:live:$login");

        my $complete = sub {
            my ($cover) = @_;
            $items[$item_index] = _buildSavedChannelMenuItem(
                $login,
                $cover,
            );

            $cb->({ items => \@items }) unless --$pending;
            return;
        };

        if (ref $cached eq 'HASH' && $cached->{cover}) {
            $complete->($cached->{cover});
            next;
        }

        Plugins::Twitch::API::getChannel($login, sub {
            my ($data) = @_;
            my $user = $data && $data->{user};

            if ($user) {
                my $channel = _buildChannelData($client, $user);
                _cache_live_metadata($channel);
                return $complete->($channel->{cover});
            }

            return $complete->();
        });
    }

    return;
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

sub _twitchServiceImpactUiItem {
    my ($client) = @_;

    return {
        name => cstring($client, 'PLUGIN_TWITCH_SERVICE_IMPACT'),
        type => 'text',
    };
}

sub _twitchServiceImpact {
    my ($client, $cb) = @_;

    $cb->({
        items => [_twitchServiceImpactUiItem($client)],
    });

    return;
}

sub _vodDoesNotExist {
    my ($client, $cb) = @_;

    $cb->({
        items => [{
            name => cstring($client, 'PLUGIN_TWITCH_VOD_DOES_NOT_EXIST'),
            type => 'link',
        }],
    });

    return;
}

sub _buildChannelUiItem {
    my ($channel, $context) = @_;

    my $is_saved = grep {
        $_ eq $channel->{artist}
    } @{ Plugins::Twitch::Config::saved_channels() };

    my $material_url = $context && $context eq 'saved_channel'
        ? 'twitch:live:' . $channel->{artist}
        : 'twitch:live-'
            . ($is_saved ? 'saved:' : 'unsaved:')
            . $channel->{artist};

    return {
        type            => 'audio',
        favorites_type  => 'audio',
        favorites_url   => $material_url,
        play            => 'twitch:live:' . $channel->{artist},
        line1           => $channel->{artist},
        line2           => $channel->{title},
        icon            => $channel->{cover},
        image           => $channel->{cover},
        on_select       => 'play',
        duration        => 0,
        title           => $channel->{title},
        favorites_title => $channel->{title},
    };
}

sub _buildChannelData {
    my ($client, $user) = @_;

    my $stream = $user->{stream} // {};

    return {
        artist => lc($user->{login} // ''),
        title  => $stream->{title}
            // cstring($client, 'PLUGIN_TWITCH_OFFLINE'),
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
    return '' if length($query) > 2048;

    $query =~ s/^\s+|\s+$//g;

    return lc $query;
}

1;
