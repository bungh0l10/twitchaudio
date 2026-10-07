package Plugins::Twitch::Plugin;

use strict;
use warnings;

use parent qw(Slim::Plugin::OPMLBased);

use Slim::Control::Request ();
use Slim::Control::XMLBrowser ();
use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring string);
use Slim::Utils::Cache;

use Plugins::Twitch::API;
use Plugins::Twitch::Config ();
use Plugins::Twitch::OAuth ();
use Plugins::Twitch::HLSStream ();

my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.twitch',
    defaultLevel => 'ERROR',
    description  => 'PLUGIN_TWITCH_DESCRIPTION',
    logGroups    => 'SCANNER',
});

my $material_actions_registered;
my $channel_commands_registered;
my $status_action_command_registered;

my $TWITCH_STATUS_URL = 'https://status.twitch.com/';

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

sub _channel_action_details {
    my ($method, $url) = @_;

    my ($state, $login) = $url =~
        /^twitch:live-(saved|unsaved):([a-z0-9_]{4,25})$/;

    my $valid_transition = (
        $method eq 'add' && ($state // '') eq 'unsaved'
    ) || (
        $method eq 'remove' && ($state // '') eq 'saved'
    );

    return unless $login && $valid_transition;

    return {
        login => $login,
        method => $method,
        title => $method eq 'add'
            ? 'PLUGIN_TWITCH_ADD_TO_MY_CHANNELS'
            : 'PLUGIN_TWITCH_REMOVE_FROM_MY_CHANNELS',
        url => $url,
    };
}

sub _change_saved_channel {
    my ($method, $url, $client) = @_;

    my $details = _channel_action_details($method, $url);
    return unless $details;

    my $changed = $method eq 'add'
        ? Plugins::Twitch::Config::add_saved_channel($details->{login}, $client)
        : Plugins::Twitch::Config::remove_saved_channel($details->{login}, $client);

    return {
        changed => $changed ? 1 : 0,
        count   => scalar @{ Plugins::Twitch::Config::saved_channels($client) },
    };
}

sub _saved_channel_command {
    my ($request) = @_;

    my $result = _change_saved_channel(
        $request->getParam('_method') // '',
        $request->getParam('url') // '',
        $request->client,
    );

    unless ($result) {
        $request->setStatusBadParams();
        return;
    }

    $request->addResult('changed', $result->{changed});
    $request->addResult('count', $result->{count});
    $request->setStatusDone();

    return;
}

sub _channel_actions_feed {
    my ($client, $method, $url, $menu_mode) = @_;

    my $details = _channel_action_details($method, $url);
    return unless $details;

    my $item = {
        name => cstring(
            $client,
            $details->{title},
        ),
        type => 'link',
    };

    if ($menu_mode) {
        $item->{isContextMenu} = 1;
        $item->{refresh} = 1;
        $item->{jive} = {
            nextWindow => 'parent',
            actions => {
                go => {
                    # SlimBrowse uses 0 to address the current player.
                    player => 0,
                    cmd => ['twitch', 'channels', $details->{method}],
                    params => { url => $details->{url} },
                },
            },
        };
    } else {
        $item->{url} = sub {
            my ($action_client, $cb) = @_;

            _change_saved_channel(
                $details->{method},
                $details->{url},
                $action_client,
            );
            $cb->({
                items => [{
                    name => cstring($action_client, 'COMPLETE'),
                    type => 'text',
                }],
            });
            return;
        };
    }

    return { items => [$item] };
}

sub _channel_actions_command {
    my ($request) = @_;

    my $method = $request->getParam('method') // '';
    my $url = $request->getParam('url') // '';
    unless (_channel_action_details($method, $url)) {
        $request->setStatusBadParams();
        return;
    }

    $request->addParam('_index', 0)
        unless defined $request->getParam('_index');
    $request->addParam('_quantity', 10)
        unless defined $request->getParam('_quantity');

    Slim::Control::XMLBrowser::cliQuery(
        'twitch_channel_actions',
        sub {
            my ($client, $cb) = @_;
            $cb->(_channel_actions_feed(
                $client,
                $method,
                $url,
                $request->getParam('menu'),
            ));
        },
        $request,
    );

    return;
}

sub _register_channel_commands {
    return if $channel_commands_registered;

    Slim::Control::Request::addDispatch(
        ['twitch', 'channels', '_method'],
        [0, 0, 1, \&_saved_channel_command],
    );
    Slim::Control::Request::addDispatch(
        ['twitch_channel_actions', 'items', '_index', '_quantity'],
        [1, 1, 1, \&_channel_actions_command],
    );

    $channel_commands_registered = 1;
    return;
}

sub _twitch_status_actions_feed {
    my ($client) = @_;

    return {
        items => [{
            name => cstring(
                $client,
                'PLUGIN_TWITCH_OPEN_STATUS',
            ),
            type    => 'link',
            weblink => $TWITCH_STATUS_URL,
        }],
    };
}

sub _twitch_status_actions_command {
    my ($request) = @_;

    $request->addParam('_index', 0)
        unless defined $request->getParam('_index');
    $request->addParam('_quantity', 10)
        unless defined $request->getParam('_quantity');

    Slim::Control::XMLBrowser::cliQuery(
        'twitch_status_actions',
        sub {
            my ($client, $cb) = @_;
            $cb->(_twitch_status_actions_feed($client));
        },
        $request,
    );

    return;
}

sub _register_status_action_command {
    return if $status_action_command_registered;

    Slim::Control::Request::addDispatch(
        ['twitch_status_actions', 'items', '_index', '_quantity'],
        [1, 1, 1, \&_twitch_status_actions_command],
    );

    $status_action_command_registered = 1;
    return;
}

sub initPlugin {
    my ($class) = @_;

    Plugins::Twitch::Config::init();
    Plugins::Twitch::OAuth::init();

    if (main::WEBUI()) {
        require Plugins::Twitch::Settings;
        Plugins::Twitch::Settings->new;
        require Plugins::Twitch::PlayerSettings;
        Plugins::Twitch::PlayerSettings->new;
    }

    $class->SUPER::initPlugin(
        feed   => \&handleFeed,
        tag    => 'twitch',
        menu   => 'radios',
        is_app => 1,
        weight => 1,
    );

    # Material asks for up to 25,000 items. Bound the CLI window so it uses its
    # native scroll-to-load behavior instead of draining every Helix page.
    Slim::Control::Request::addDispatch(
        ['twitch', 'items', '_index', '_quantity'],
        [1, 1, 1, \&_browse_command],
    );

    _register_channel_commands();
    _register_status_action_command();
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

sub shutdownPlugin {
    Plugins::Twitch::OAuth::shutdown();
    Plugins::Twitch::API::clearVodLists();
}

sub _browse_command {
    my ($request) = @_;
    my $quantity = $request->getParam('_quantity');
    $request->addParam('_quantity', 100)
        if defined $quantity && $quantity =~ /^\d+$/ && $quantity > 100;
    Slim::Control::XMLBrowser::cliQuery('twitch', \&handleFeed, $request);
}

sub handleFeed {
    my ($client, $cb) = @_;

    Plugins::Twitch::Config::initialize_player($client);

    $cb->({
        items => [
            _buildMainMenu($client),
            (Plugins::Twitch::Config::menu_visible('show_local_channels', $client)
                ? (_buildSavedChannelsMenu($client)) : ()),
            (Plugins::Twitch::OAuth::connected(Plugins::Twitch::Config::account_id($client))
                ? ((Plugins::Twitch::Config::menu_visible('show_followed_live', $client)
                        ? (_buildFollowedMenu($client, 1)) : ()),
                   (Plugins::Twitch::Config::menu_visible('show_followed', $client)
                        ? (_buildFollowedMenu($client, 0)) : ())) : ()),
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
        }, $client);

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
            if $api_error && !$data;

        return _channelDoesNotExist($client, $cb)
            unless $data;

        my $user = $data;
        my $channel = _buildChannelData($client, $user);

        _cache_live_metadata($channel);

        Plugins::Twitch::API::getVods($user->{login}, 1, sub {
            my ($vod_data, $vod_error) = @_;

            my @items = (_buildChannelUiItem($channel, $context, $client));

            push @items, _twitchServiceImpactUiItem($client)
                if $vod_error;

            for my $vod_type (
                ['PLUGIN_TWITCH_HIGHLIGHTS', 'highlights'],
                ['PLUGIN_TWITCH_ARCHIVE',    'archives'],
            ) {
                my ($title_key, $type) = @$vod_type;
                next unless @{ _vod_items($vod_data, $type) };

                push @items, _buildVodMenuItem(
                    $user->{login},
                    $channel,
                    cstring($client, $title_key),
                    $type,
                    $context,
                );
            }

            $cb->({ items => \@items });

            return;
        }, $client);

        return;
    }, $client);

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

sub _vod_items {
    my ($data, $type) = @_;
    return $data && ref $data->{$type} eq 'ARRAY' ? $data->{$type} : [];
}

sub _buildVodMenuItem {
    my ($login, $channel, $title, $type, $context) = @_;

    my $cover = $channel->{cover};

    return {
        name  => $title,
        type  => 'link',
        icon  => $cover,
        image => $cover,
        forceRefresh => 1,

        url => sub {
            my ($client, $cb, $args) = @_;

            Plugins::Twitch::API::getVodRange($login, $type, $args && $args->{index},
                $args && $args->{quantity}, sub {
                my ($data, $api_error) = @_;

                my $videos = $data ? $data->{items} : [];

                unless (@$videos) {
                    return $cb->({ items => [{ type => 'text',
                        name => cstring($client, 'PLUGIN_TWITCH_LOGIN_REQUIRED') }] })
                        if $api_error && $api_error->{type} eq 'auth';
                    return _twitchServiceImpact($client, $cb)
                        if $api_error;
                    return $cb->({ items => [] });
                }

                my @items;

                for my $video (@$videos) {
                    my $item = _buildVodUiItem($video);
                    push @items, $item if $item;
                }

                # A temporary error row stops automatic loading. Refreshing the
                # list retries from the last successful cursor, preserving IDs.
                push @items, { type => 'text', name => cstring($client,
                    $api_error->{type} eq 'auth' ? 'PLUGIN_TWITCH_LOGIN_REQUIRED'
                        : 'PLUGIN_TWITCH_VIDEO_RELOAD') } if $api_error;

                $cb->({ items => \@items, offset => 0, forceRefresh => 1,
                    # XMLBrowser requires a positive total to normalize ranges.
                    # One beyond the known prefix signals that more can load.
                    total => scalar(@items) + (!$api_error && $data->{more} ? 1 : 0),
                });

                return;
            }, $client);

            return;
        },
    };
}

sub _buildVodUiItem {
    my ($vod) = @_;
    return unless $vod && $vod->{id} && $vod->{title};
    return {
        type => 'audio', name => $vod->{title}, line1 => $vod->{title},
        icon => $vod->{thumbnail}, image => $vod->{thumbnail},
        play => 'twitch:vod:' . $vod->{id}, duration => $vod->{duration} || 0,
    };
}

sub _buildVodMetaUiItem { return _buildVodUiItem(@_); }

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
        name => cstring($client, 'PLUGIN_TWITCH_MY_CHANNELS')
            . (Plugins::Twitch::Config::use_personal_channels($client)
                ? " \x{b7} " . $client->name
                : ''),
        type => 'link',
        url  => sub {
            my ($client, $cb) = @_;
            my @channels = @{ Plugins::Twitch::Config::saved_channels($client) };

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

# Material displays the second line as HTML. Escape external titles and remove
# line breaks so a Twitch title cannot inject markup or additional list lines.
sub _list_text {
    my ($text) = @_;
    $text //= '';
    $text =~ s/[\r\n]+/ /g;
    $text =~ s/&/&amp;/g;
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;
    return $text;
}

sub _buildChannelListItem {
    my ($client, $login, $channel) = @_;
    my $is_saved = grep { $_ eq $login } @{ Plugins::Twitch::Config::saved_channels($client) };
    my $cover = $channel && $channel->{artwork};
    my $item = {
        name => $login,
        type => 'link',
        itemActions => {
            info => {
                command => ['twitch_channel_actions', 'items'],
                fixedParams => {
                    method => $is_saved ? 'remove' : 'add',
                    url => 'twitch:live-' . ($is_saved ? 'saved:' : 'unsaved:') . $login,
                },
            },
        },
        url => sub {
            my ($client, $cb) = @_;
            return _searchChannelLogin($client, $cb, $login, $is_saved ? 'saved_channel' : undef);
        },
    };
    $item->{icon} = $item->{image} = $cover if defined $cover && length $cover;
    return $item;
}

sub _loadSavedChannelItems {
    my ($client, $channels, $cb) = @_;
    my $cache = Slim::Utils::Cache->new;
    my (%known, @missing);
    for my $login (@$channels) {
        my $cached = $cache->get("twitch:live:$login");
        if (ref $cached eq 'HASH' && $cached->{cover}) {
            $known{$login} = { artwork => $cached->{cover} };
        } else {
            push @missing, $login;
        }
    }
    my $complete = sub {
        my ($loaded) = @_;
        for my $login (keys %{ $loaded || {} }) {
            $known{$login} = $loaded->{$login};
            _cache_live_metadata(_buildChannelData($client, $loaded->{$login}));
        }
        $cb->({ items => [map {
            my $login = $_;
            my $channel = $known{$login};
            _buildChannelListItem($client, $login, $channel);
        } @$channels] });
    };
    return $complete->({}) unless @missing;
    Plugins::Twitch::API::getChannels(\@missing, $complete, $client);
}

sub _buildFollowedMenu {
    my ($client, $live_only, $cursor) = @_;
    my $identity = Plugins::Twitch::OAuth::session_key(Plugins::Twitch::Config::account_id($client));
    return {
        name => cstring($client, $cursor ? 'PLUGIN_TWITCH_MORE'
            : $live_only ? 'PLUGIN_TWITCH_FOLLOWED_LIVE' : 'PLUGIN_TWITCH_FOLLOWED'),
        type => 'link',
        url => sub {
            my ($client, $cb) = @_;
            return $cb->({items => [{type => 'text', name => cstring($client, 'PLUGIN_TWITCH_LOGIN_REQUIRED')}]})
                if $cursor && $identity ne Plugins::Twitch::OAuth::session_key(Plugins::Twitch::Config::account_id($client));
            Plugins::Twitch::API::getFollowedChannels($live_only, $cursor, sub {
                my ($data, $error) = @_;
                if ($error) {
                    return $cb->({ items => [{ type => 'text', name => cstring($client,
                        $error->{type} eq 'auth' ? 'PLUGIN_TWITCH_LOGIN_REQUIRED' : 'PLUGIN_TWITCH_SERVICE_IMPACT') }] });
                }
                my @items = map { _buildChannelListItem($client, $_->{login}, $_) } @{ $data->{items} };
                push @items, _buildFollowedMenu($client, $live_only, $data->{cursor}) if $data->{cursor};
                push @items, { type => 'text', name => cstring($client, 'PLUGIN_TWITCH_NO_FOLLOWED') } unless @items;
                $cb->({ items => \@items });
            }, $client);
        },
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

sub _twitchServiceImpactUiItem {
    my ($client) = @_;

    return {
        name => cstring($client, 'PLUGIN_TWITCH_SERVICE_IMPACT'),
        type => 'text',
        itemActions => {
            info => {
                command => ['twitch_status_actions', 'items'],
            },
        },
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
    my ($channel, $context, $client) = @_;

    my $is_saved = grep {
        $_ eq $channel->{artist}
    } @{ Plugins::Twitch::Config::saved_channels($client) };

    my $action_url = $context && $context eq 'saved_channel'
        ? 'twitch:live:' . $channel->{artist}
        : 'twitch:live-'
            . ($is_saved ? 'saved:' : 'unsaved:')
            . $channel->{artist};

    my $cover = $channel->{cover};

    my $item = {
        type            => 'audio',
        favorites_type  => 'audio',
        favorites_url   => $action_url,
        play            => 'twitch:live:' . $channel->{artist},
        line1           => $channel->{artist},
        line2           => _list_text($channel->{title}),
        icon            => $cover,
        image           => $cover,
        on_select       => 'play',
        duration        => 0,
        title           => $channel->{title},
        favorites_title => $channel->{title},
    };

    unless ($context && $context eq 'saved_channel') {
        $item->{itemActions} = {
            info => {
                command => ['twitch_channel_actions', 'items'],
                fixedParams => {
                    method => $is_saved ? 'remove' : 'add',
                    url => $action_url,
                },
            },
        };
    }

    return $item;
}

sub _buildChannelData {
    my ($client, $channel) = @_;
    return {
        %$channel,
        artist => lc($channel->{login} // ''),
        title => $channel->{title} // ($channel->{is_live} ? $channel->{login} : cstring($client,
            defined $channel->{is_live} ? 'PLUGIN_TWITCH_OFFLINE' : 'PLUGIN_TWITCH_STATUS_UNKNOWN')),
        cover => $channel->{artwork} // '',
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
