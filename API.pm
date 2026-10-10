package Plugins::Twitch::API;

use strict;
use warnings;
use Slim::Utils::Cache;
use Plugins::Twitch::Config ();
use Plugins::Twitch::GraphQL ();
use Plugins::Twitch::Helix ();
use Plugins::Twitch::OAuth ();

my %vod_lists;

sub clearVodLists { %vod_lists = (); }
sub _context_key {
    my ($client) = @_;
    return Plugins::Twitch::OAuth::session_key(Plugins::Twitch::Config::account_id($client))
        . ':' . Plugins::Twitch::Config::helix_metadata($client);
}

# XMLBrowser asks for numeric ranges, whereas Helix provides opaque cursors.
# Retain an ordered prefix so overlapping ranges and playback lookups keep their
# indices. The cache also survives XMLBrowser rebuilding its coderef menus.
sub getVodRange {
    my ($login, $type, $index, $quantity, $callback, $client) = @_;
    $index ||= 0;
    my $key = ($client ? ($client->can('id') ? $client->id : "$client") : 'server') . ":$login:$type";
    my $identity = _context_key($client);
    for my $old (keys %vod_lists) {
        delete $vod_lists{$old} if !$vod_lists{$old}{busy}
            && time() - $vod_lists{$old}{touched} > 3600;
    }
    my $state = $vod_lists{$key};
    $state = undef if $state && $state->{restart} && !$index;
    if ($state && $state->{identity} ne $identity) {
        return $callback->({ items => [], more => 0 },
            { type => 'auth', message => 'Twitch session changed; reopen the video list' }) if $index;
        $state = undef;
    }
    unless ($state) {
        # Bound idle lists; an in-flight request always retains its own state.
        my @old = sort { $vod_lists{$a}{touched} <=> $vod_lists{$b}{touched} }
            grep { !$vod_lists{$_}{busy} } keys %vod_lists;
        delete $vod_lists{shift @old} while keys(%vod_lists) >= 32 && @old;
        $state = $vod_lists{$key} = {
            login => $login, type => $type, identity => $identity, client => $client,
            items => [], seen => {}, cursors => {}, queue => [],
        };
    }
    $state->{touched} = time();
    push @{ $state->{queue} }, {
        end => $quantity ? $index + $quantity : undef, callback => $callback,
    };
    _pumpVodRange($state);
}

sub _pumpVodRange {
    my ($state) = @_;
    return if $state->{busy};
    while (my $job = $state->{queue}[0]) {
        if ($state->{complete} || (defined $job->{end} && @{ $state->{items} } >= $job->{end})) {
            shift @{ $state->{queue} };
            $job->{callback}->({ items => [@{ $state->{items} }], more => $state->{complete} ? 0 : 1 });
            return if $state->{busy};
            next;
        }
        $state->{busy} = 1;
        getVodPage($state->{login}, $state->{type}, $state->{next_page}, sub {
            my ($data, $error) = @_;
            if ($state->{identity} ne _context_key($state->{client})) {
                $error = { type => 'auth', message => 'Twitch session changed' };
                $state->{items} = [];
            }
            my $cursor = $data && $data->{next_page} ? $data->{next_page}{cursor} : undef;
            if (!$error && defined $cursor && $state->{cursors}{$cursor}) {
                $error = { type => 'invalid_response', message => 'Repeated Twitch video cursor' };
            }
            if (!$error) {
                my @items = grep { $_->{id} && $_->{title} && !$state->{seen}{$_->{id}}++ }
                    @{ $data && $data->{items} ? $data->{items} : [] };
                $state->{empty_pages} = @items ? 0 : ($state->{empty_pages} || 0) + 1;
                $error = { type => 'invalid_response', message => 'Twitch video pages contain no new videos' }
                    if $cursor && $state->{empty_pages} >= 10;
                unless ($error) {
                    push @{ $state->{items} }, @items;
                    $state->{cursors}{$cursor} = 1 if defined $cursor;
                    $state->{next_page} = $data->{next_page};
                    $state->{complete} = !$data->{next_page};
                }
            }
            $state->{busy} = 0;
            if ($error) {
                $state->{restart} = 1 if $error->{type} eq 'invalid_response'
                    || ($error->{status} || 0) == 400;
                # Keep the successful prefix and cursor for a retry. Never mix
                # anonymous page one into an already-started Helix collection.
                my @waiting = splice @{ $state->{queue} };
                $_->{callback}->({ items => [@{ $state->{items} }], more => 0 }, $error) for @waiting;
                return;
            }
            _pumpVodRange($state);
        }, $state->{client});
        return;
    }
}

# Public metadata uses the same data model with either provider. Playback is
# always anonymous; a Helix OAuth token is not a Twitch playback token.
sub _metadata {
    my ($method, @args) = @_;
    my $client = ref $args[-1] eq 'CODE' ? undef : pop @args;
    my $callback = pop @args;
    my $account = Plugins::Twitch::Config::account_id($client);
    my $graphql = Plugins::Twitch::GraphQL->can($method);
    return $graphql->(@args, $callback)
        unless Plugins::Twitch::Config::helix_metadata($client) && Plugins::Twitch::OAuth::connected($account);
    my $helix = Plugins::Twitch::Helix->can($method);
    return $helix->(@args, sub {
        my ($data, $error) = @_;
        return $graphql->(@args, $callback) if $error;
        $callback->($data);
    }, $account);
}

sub getChannel { _metadata('getChannel', @_); }
sub getVods { _metadata('getVods', @_); }
sub getVodMeta {
    my ($id, $callback, $client) = @_;
    _metadata('getVodMeta', $id, sub {
        my ($vod, $error) = @_;
        return $callback->($vod, $error) unless $vod;
        my $cache = Slim::Utils::Cache->new;
        my $key = "twitch:vod-category:$id";
        if (exists $vod->{game_name}) {
            $cache->set($key, { game_name => $vod->{game_name} },
                Plugins::Twitch::Config::cache_ttl()) unless $error;
            return $callback->($vod, $error);
        }
        my $cached = $cache->get($key);
        return $callback->({ %$vod, game_name => $cached->{game_name} }, $error)
            if ref $cached eq 'HASH';

        # Helix videos have no category field. Enrich this one VOD anonymously;
        # lists and their Helix pagination never need a lookup per video.
        Plugins::Twitch::GraphQL::getVodMeta($id, sub {
            my ($graphql, $category_error) = @_;
            my $name = $graphql ? $graphql->{game_name} : undef;
            $cache->set($key, { game_name => $name },
                Plugins::Twitch::Config::cache_ttl()) if $graphql && !$category_error;
            # Category lookup failure must not discard successful Helix data.
            $callback->({ %$vod, game_name => $name }, $error);
        });
    }, $client);
}
sub getAudioUrl { Plugins::Twitch::GraphQL::getAudioUrl(@_); }
sub getVodAudioUrl { Plugins::Twitch::GraphQL::getVodAudioUrl(@_); }
sub getFollowedChannels {
    my ($live_only, $cursor, $callback, $client) = @_;
    my $account = Plugins::Twitch::Config::account_id($client);
    my $identity = _context_key($client);
    Plugins::Twitch::Helix::getFollowedChannels($live_only, $cursor, sub {
        return $callback->(undef, {type => 'auth', message => 'Twitch account selection changed'})
            if $identity ne _context_key($client);
        $callback->(@_);
    }, $account);
}

sub getVodPage {
    my ($login, $type, $page, $callback, $client) = @_;
    my $account = Plugins::Twitch::Config::account_id($client);
    my $invalid = { type => 'invalid_response', message => 'Invalid Twitch video page' };
    return $callback->(undef, $invalid) unless $type eq 'highlights' || $type eq 'archives';
    if (defined $page) {
        return $callback->(undef, $invalid) unless ref $page eq 'HASH'
            && ($page->{provider} || '') eq 'helix'
            && ($page->{login} || '') eq $login && ($page->{type} || '') eq $type
            && (!exists $page->{account_id} || $page->{account_id} eq $account);
        return $callback->(undef, {type => 'auth', message => 'Twitch session changed'})
            if exists $page->{session_key} && $page->{session_key} ne Plugins::Twitch::OAuth::session_key($account);
    }
    my $anonymous = sub {
        Plugins::Twitch::GraphQL::getVods($login, 100, sub {
            my ($data, $error) = @_;
            $callback->($data ? { items => $data->{$type} || [] } : undef, $error);
        });
    };
    return $anonymous->() unless defined $page
        || (Plugins::Twitch::Config::helix_metadata($client) && Plugins::Twitch::OAuth::connected($account));
    Plugins::Twitch::Helix::getVodPage($login, $type, $page, sub {
        my ($data, $error) = @_;
        # Only the first page can fall back. A Helix cursor cannot be applied to
        # GraphQL, and restarting anonymously would silently repeat page one.
        return $anonymous->() if $error && !defined $page;
        if ($data && $data->{next_page}) {
            $data->{next_page} = {
                %{ $data->{next_page} }, provider => 'helix', login => $login, type => $type, account_id => $account,
                session_key => Plugins::Twitch::OAuth::session_key($account),
            };
        }
        $callback->($data, $error);
    }, $account);
}

# Batch the Helix lookup, but bound concurrency for the anonymous provider.
# Missing or failed channels remain absent; callers must not infer "offline".
sub getChannels {
    my ($logins, $callback, $client) = @_;
    my $account = Plugins::Twitch::Config::account_id($client);
    return $callback->({}) unless @$logins;
    my $anonymous = sub {
        my %channels;
        my @queue = @$logins;
        my $active = 0;
        my $last_error;
        my $pump;
        $pump = sub {
            while ($active < 4 && @queue) {
                my $login = shift @queue;
                ++$active;
                Plugins::Twitch::GraphQL::getChannel($login, sub {
                    my ($channel, $error) = @_;
                    $channels{$login} = $channel if $channel;
                    $last_error = $error if $error;
                    --$active;
                    if (!@queue && !$active) {
                        my $done = $callback;
                        undef $pump;
                        return $done->(\%channels, $last_error);
                    }
                    $pump->() if $pump;
                });
            }
        };
        $pump->();
    };
    return $anonymous->() unless Plugins::Twitch::Config::helix_metadata($client)
        && Plugins::Twitch::OAuth::connected($account);
    Plugins::Twitch::Helix::getChannels($logins, sub {
        my ($channels, $error) = @_;
        return $anonymous->() if $error;
        $callback->($channels);
    }, $account);
}

1;
