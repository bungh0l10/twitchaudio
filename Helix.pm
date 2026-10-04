package Plugins::Twitch::Helix;

use strict;
use warnings;
use URI;
use Plugins::Twitch::HTTP ();
use Plugins::Twitch::OAuth ();

my $rate_limit_until = 0;

sub _invalid { return { type => 'invalid_response', message => 'Invalid Twitch Helix response' }; }

sub _get {
    my ($path, $params, $callback, $retried, $rejected) = @_;
    return $callback->(undef, { type => 'rate_limit', message => 'Twitch rate limit reached' })
        if time() < $rate_limit_until;
    Plugins::Twitch::OAuth::with_token(sub {
        my ($auth, $auth_error) = @_;
        return $callback->(undef, $auth_error) if $auth_error;
        my $url = URI->new('https://api.twitch.tv/helix/' . $path);
        my %query = %$params;
        $query{user_id} = $auth->{user_id} if $path =~ m{^(?:channels|streams)/followed$};
        $url->query_form(%query);
        my $token = $auth->{access_token};
        my $identity = Plugins::Twitch::OAuth::session_key();
        Plugins::Twitch::HTTP::request('GET', $url->as_string, {
            'Client-ID' => $auth->{client_id}, Authorization => "Bearer $token",
        }, undef, sub {
            my ($data, $error) = @_;
            return $callback->(undef, { type => 'auth', message => 'Twitch session changed' })
                if $identity ne Plugins::Twitch::OAuth::session_key();
            if ($error && ($error->{status} || 0) == 401 && !$retried) {
                return _get($path, $params, $callback, 1, $token);
            }
            if ($error && ($error->{status} || 0) == 429) {
                my $reset = $error->{retry_at};
                $rate_limit_until = defined $reset && $reset =~ /^\d+$/ && $reset > time()
                    ? $reset : time() + 60;
            }
            return $callback->(undef, $error) if $error;
            return $callback->(undef, _invalid()) unless ref $data->{data} eq 'ARRAY'
                && !grep { ref $_ ne 'HASH' } @{ $data->{data} };
            $callback->($data);
        });
    }, $rejected);
}

sub getChannels {
    my ($logins, $callback) = @_;
    return $callback->({}) unless @$logins;
    # Twitch accepts at most 100 logins per request.
    if (@$logins > 100) {
        my @rest = @$logins;
        my @first = splice @rest, 0, 100;
        return getChannels(\@first, sub {
            my ($first, $error) = @_;
            return $callback->(undef, $error) if $error;
            getChannels(\@rest, sub {
                my ($rest, $rest_error) = @_;
                return $callback->(undef, $rest_error) if $rest_error;
                $callback->({ %$first, %$rest });
            });
        });
    }
    _get('users', { login => $logins }, sub {
        my ($users, $error) = @_;
        return $callback->(undef, $error) if $error;
        _get('streams', { user_login => $logins, first => 100 }, sub {
            my ($streams, $stream_error) = @_;
            return $callback->(undef, $stream_error) if $stream_error;
            my %live = map { $_->{user_id} => $_ } @{ $streams->{data} };
            my %channels = map {
                my $user = $_;
                my $stream = $live{$user->{id}};
                $user->{login} => {
                    id => $user->{id}, login => $user->{login},
                    display_name => $user->{display_name}, artwork => $user->{profile_image_url},
                    is_live => $stream ? 1 : 0, title => $stream ? $stream->{title} : undef,
                }
            } @{ $users->{data} };
            $callback->(\%channels);
        });
    });
}

sub getChannel {
    my ($login, $callback) = @_;
    getChannels([$login], sub {
        my ($channels, $error) = @_;
        $callback->($channels ? $channels->{$login} : undef, $error);
    });
}

sub _video {
    my ($v) = @_;
    my $duration = 0;
    my %unit = (h => 3600, m => 60, s => 1);
    my $text = $v->{duration} || '';
    while ($text =~ /(\d+)([hms])/g) { $duration += $1 * $unit{$2}; }
    my $thumbnail = $v->{thumbnail_url} || '';
    $thumbnail =~ s/%\{width\}/640/g;
    $thumbnail =~ s/%\{height\}/360/g;
    return {
        id => $v->{id}, title => $v->{title}, artist => $v->{user_login},
        thumbnail => $thumbnail, duration => $duration, created_at => $v->{created_at},
    };
}

sub getVodMeta {
    my ($id, $callback) = @_;
    _get('videos', { id => $id }, sub {
        my ($data, $error) = @_;
        $callback->($data && @{ $data->{data} } ? _video($data->{data}[0]) : undef, $error);
    });
}

sub getVods {
    my ($login, $limit, $callback) = @_;
    $limit = 10 unless $limit && $limit > 0;
    $limit = 100 if $limit > 100;
    _get('users', { login => $login }, sub {
        my ($users, $error) = @_;
        return $callback->(undef, $error) if $error;
        return $callback->({ highlights => [], archives => [] }) unless @{ $users->{data} };
        my $id = $users->{data}[0]{id};
        _get('videos', { user_id => $id, type => 'highlight', sort => 'time', first => $limit }, sub {
            my ($highlights, $error) = @_;
            return $callback->(undef, $error) if $error;
            _get('videos', { user_id => $id, type => 'archive', sort => 'time', first => $limit }, sub {
                my ($archives, $error) = @_;
                return $callback->(undef, $error) if $error;
                $callback->({
                    highlights => [map { _video($_) } @{ $highlights->{data} }],
                    archives => [map { _video($_) } @{ $archives->{data} }],
                });
            });
        });
    });
}

# A selected VOD category is loaded one page at a time. Keep the broadcaster ID
# with the cursor so subsequent pages need only one request and retain the filter.
sub getVodPage {
    my ($login, $type, $page, $callback) = @_;
    my %types = (highlights => 'highlight', archives => 'archive');
    return $callback->(undef, _invalid()) unless $types{$type};
    my $fetch = sub {
        my ($id) = @_;
        my %params = (user_id => $id, type => $types{$type}, sort => 'time', first => 100);
        $params{after} = $page->{cursor} if $page;
        _get('videos', \%params, sub {
            my ($data, $error) = @_;
            return $callback->(undef, $error) if $error;
            my $cursor = ref $data->{pagination} eq 'HASH' ? $data->{pagination}{cursor} : undef;
            my $next;
            if (defined $cursor && !ref $cursor && length $cursor) {
                # Do not offer a link back to the same page on a broken response.
                return $callback->(undef, _invalid()) if $page && $cursor eq $page->{cursor};
                $next = { user_id => $id, cursor => $cursor };
            }
            $callback->({ items => [map { _video($_) } @{ $data->{data} }], next_page => $next });
        });
    };
    if ($page) {
        return $callback->(undef, _invalid()) unless ref $page eq 'HASH'
            && ($page->{user_id} || '') =~ /^\d+$/ && $page->{cursor} && !ref $page->{cursor};
        return $fetch->($page->{user_id});
    }
    _get('users', { login => $login }, sub {
        my ($users, $error) = @_;
        return $callback->(undef, $error) if $error;
        return $callback->({ items => [] }) unless @{ $users->{data} };
        my $id = $users->{data}[0]{id};
        return $callback->(undef, _invalid()) unless defined $id && $id =~ /^\d+$/;
        $fetch->($id);
    });
}

sub getFollowedChannels {
    my ($live_only, $cursor, $callback) = @_;
    my %params = (first => 100);
    $params{after} = $cursor if $cursor;
    _get($live_only ? 'streams/followed' : 'channels/followed', \%params, sub {
        my ($data, $error) = @_;
        return $callback->(undef, $error) if $error;
        my $key = $live_only ? 'user_login' : 'broadcaster_login';
        my @logins = map { $_->{$key} } @{ $data->{data} };
        getChannels(\@logins, sub {
            my ($channels, $error) = @_;
            return $callback->(undef, $error) if $error;
            $callback->({
                items => [map { $channels->{$_} ? ($channels->{$_}) : () } @logins],
                cursor => ref $data->{pagination} eq 'HASH' ? $data->{pagination}{cursor} : undef,
            });
        });
    });
}

1;
