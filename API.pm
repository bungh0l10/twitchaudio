package Plugins::Twitch::API;

use strict;
use warnings;
use Plugins::Twitch::Config ();
use Plugins::Twitch::GraphQL ();
use Plugins::Twitch::Helix ();
use Plugins::Twitch::OAuth ();

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
