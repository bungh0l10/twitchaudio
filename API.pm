package Plugins::Twitch::API;

use strict;
use warnings;
use Plugins::Twitch::Config ();
use Plugins::Twitch::GraphQL ();
use Plugins::Twitch::Helix ();
use Plugins::Twitch::OAuth ();

my %vod_lists;

sub clearVodLists { %vod_lists = (); }

# XMLBrowser asks for numeric ranges, whereas Helix provides opaque cursors.
# Retain an ordered prefix so overlapping ranges and playback lookups keep their
# indices. The cache also survives XMLBrowser rebuilding its coderef menus.
sub getVodRange {
    my ($login, $type, $index, $quantity, $callback) = @_;
    $index ||= 0;
    my $key = "$login:$type";
    my $identity = Plugins::Twitch::OAuth::session_key();
    for my $old (keys %vod_lists) {
        delete $vod_lists{$old} if !$vod_lists{$old}{busy}
            && time() - $vod_lists{$old}{touched} > 3600;
    }
    my $state = $vod_lists{$key};
    $state = undef if $state && $state->{restart} && !$index;
    if ($state && $state->{identity} ne $identity) {
        return $callback->({ items => [@{ $state->{items} }], more => 0 },
            { type => 'auth', message => 'Twitch session changed; reopen the video list' }) if $index;
        $state = undef;
    }
    unless ($state) {
        # Bound idle lists; an in-flight request always retains its own state.
        my @old = sort { $vod_lists{$a}{touched} <=> $vod_lists{$b}{touched} }
            grep { !$vod_lists{$_}{busy} } keys %vod_lists;
        delete $vod_lists{shift @old} while keys(%vod_lists) >= 32 && @old;
        $state = $vod_lists{$key} = {
            login => $login, type => $type, identity => $identity,
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
            $error = { type => 'auth', message => 'Twitch session changed' }
                if $state->{identity} ne Plugins::Twitch::OAuth::session_key();
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
        });
        return;
    }
}

# Public metadata uses the same data model with either provider. Playback is
# always anonymous; a Helix OAuth token is not a Twitch playback token.
sub _metadata {
    my ($method, @args) = @_;
    my $callback = pop @args;
    my $graphql = Plugins::Twitch::GraphQL->can($method);
    return $graphql->(@args, $callback)
        unless Plugins::Twitch::Config::helix_metadata() && Plugins::Twitch::OAuth::connected();
    my $helix = Plugins::Twitch::Helix->can($method);
    return $helix->(@args, sub {
        my ($data, $error) = @_;
        return $graphql->(@args, $callback) if $error;
        $callback->($data);
    });
}

sub getChannel { _metadata('getChannel', @_); }
sub getVods { _metadata('getVods', @_); }
sub getVodMeta { _metadata('getVodMeta', @_); }
sub getAudioUrl { Plugins::Twitch::GraphQL::getAudioUrl(@_); }
sub getVodAudioUrl { Plugins::Twitch::GraphQL::getVodAudioUrl(@_); }
sub getFollowedChannels { Plugins::Twitch::Helix::getFollowedChannels(@_); }

sub getVodPage {
    my ($login, $type, $page, $callback) = @_;
    my $invalid = { type => 'invalid_response', message => 'Invalid Twitch video page' };
    return $callback->(undef, $invalid) unless $type eq 'highlights' || $type eq 'archives';
    if (defined $page) {
        return $callback->(undef, $invalid) unless ref $page eq 'HASH'
            && ($page->{provider} || '') eq 'helix'
            && ($page->{login} || '') eq $login && ($page->{type} || '') eq $type;
    }
    my $anonymous = sub {
        Plugins::Twitch::GraphQL::getVods($login, 100, sub {
            my ($data, $error) = @_;
            $callback->($data ? { items => $data->{$type} || [] } : undef, $error);
        });
    };
    return $anonymous->() unless defined $page
        || (Plugins::Twitch::Config::helix_metadata() && Plugins::Twitch::OAuth::connected());
    Plugins::Twitch::Helix::getVodPage($login, $type, $page, sub {
        my ($data, $error) = @_;
        # Only the first page can fall back. A Helix cursor cannot be applied to
        # GraphQL, and restarting anonymously would silently repeat page one.
        return $anonymous->() if $error && !defined $page;
        if ($data && $data->{next_page}) {
            $data->{next_page} = {
                %{ $data->{next_page} }, provider => 'helix', login => $login, type => $type,
            };
        }
        $callback->($data, $error);
    });
}

# Batch the Helix lookup, but bound concurrency for the anonymous provider.
# Missing or failed channels remain absent; callers must not infer "offline".
sub getChannels {
    my ($logins, $callback) = @_;
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
    return $anonymous->() unless Plugins::Twitch::Config::helix_metadata()
        && Plugins::Twitch::OAuth::connected();
    Plugins::Twitch::Helix::getChannels($logins, sub {
        my ($channels, $error) = @_;
        return $anonymous->() if $error;
        $callback->($channels);
    });
}

1;
