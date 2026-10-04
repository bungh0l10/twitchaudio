package Plugins::Twitch::OAuth;

use strict;
use warnings;
use JSON::XS qw(encode_json decode_json);
use File::Spec;
use File::Temp qw(tempfile);
use Slim::Utils::Prefs qw(preferences);
use Slim::Utils::Timers;
use Plugins::Twitch::HTTP ();
use Plugins::Twitch::Config ();

use constant AUTH_URL => 'https://id.twitch.tv/oauth2/';
use constant SCOPE => 'user:read:follows';

my $session = {};
my $pending;
my $generation = 0;
my @waiters;
my $busy = 0;
my $retry_after = 0;
my $status = 'disconnected';
my $timer_owner = 'Plugins::Twitch::OAuth';

sub _error { return { type => 'auth', message => $_[0] || 'Twitch login required' }; }
sub _file { File::Spec->catfile(Slim::Utils::Prefs::dir(), 'twitch-oauth.json') }

# Keep credentials out of LMS preferences (and its preference API/debug logs).
# File::Temp creates mode 0600; rename keeps token rotation atomic on disk.
sub _persist {
    my ($value) = @_;
    my ($fh, $path);
    my $ok = eval {
        ($fh, $path) = tempfile('twitch-oauth-XXXXXX',
            DIR => Slim::Utils::Prefs::dir(), UNLINK => 0);
        binmode $fh;
        print {$fh} encode_json($value) or die 'write';
        close $fh or die 'close';
        rename $path, _file() or die 'rename';
        1;
    };
    unlink $path if !$ok && $path && -e $path;
    return $ok;
}

sub init {
    Plugins::Twitch::OAuth::shutdown();
    $session = {};
    if (open my $fh, '<', _file()) {
        local $/;
        my $stored = eval { decode_json(<$fh>) };
        close $fh;
        $session = $stored if ref $stored eq 'HASH'
            && ($stored->{client_id} || '') eq Plugins::Twitch::Config::oauth_client_id();
    }
    $session->{validated_at} = 0;
    $retry_after = 0;
    $status = connected() ? 'checking' : 'disconnected';
    _tick();
}

sub shutdown {
    ++$generation;
    Slim::Utils::Timers::killTimers($timer_owner, \&_tick);
    Slim::Utils::Timers::killTimers($timer_owner, \&_poll);
    $pending = undef;
    _finish(undef, _error('Twitch session changed'));
}

sub connected {
    return $session->{access_token}
        && ($session->{client_id} || '') eq Plugins::Twitch::Config::oauth_client_id() ? 1 : 0;
}

sub session_key { return $generation . ':' . ($session->{user_id} || ''); }

sub state {
    return {
        status => $status,
        connected => connected(),
        login => $session->{login} || '',
        user_code => $pending ? $pending->{user_code} : '',
        verification_uri => $pending ? $pending->{verification_uri} : '',
    };
}

sub disconnect {
    my $old = $session;
    $session = {};
    Plugins::Twitch::OAuth::shutdown();
    $retry_after = 0;
    $status = _persist({}) ? 'disconnected' : 'storage_error';
    if ($old->{access_token} && $old->{client_id}) {
        Plugins::Twitch::HTTP::form(AUTH_URL . 'revoke', {
            client_id => $old->{client_id}, token => $old->{access_token},
        }, sub {});
    }
    _schedule_tick();
}

sub start {
    my ($callback) = @_;
    my $client_id = Plugins::Twitch::Config::oauth_client_id();
    return $callback->(undef, _error('Missing Twitch client ID')) unless $client_id;
    disconnect();
    my $epoch = $generation;
    $status = 'starting';
    Plugins::Twitch::HTTP::form(AUTH_URL . 'device', {
        client_id => $client_id, scopes => SCOPE,
    }, sub {
        my ($data, $error) = @_;
        return $callback->(undef, _error('Twitch session changed')) if $epoch != $generation;
        unless (!$error && $data->{device_code} && $data->{user_code}
            && ($data->{expires_in} || 0) > 0
            && ($data->{verification_uri} || '') =~ m{^https://(?:www\.)?twitch\.tv/activate(?:[/?]|$)}) {
            $status = 'error';
            return $callback->(undef, _error('Unable to start Twitch login'));
        }
        $pending = {
            %$data, client_id => $client_id,
            expires_at => time() + $data->{expires_in},
            interval => ($data->{interval} || 5) < 5 ? 5 : ($data->{interval} || 5),
        };
        $status = 'pending';
        _schedule_poll();
        return $callback->(state());
    });
}

sub _schedule_poll {
    Slim::Utils::Timers::killTimers($timer_owner, \&_poll);
    Slim::Utils::Timers::setTimer($timer_owner, time() + $pending->{interval}, \&_poll)
        if $pending;
}

sub _poll {
    return unless $pending;
    if (time() >= $pending->{expires_at}) {
        $pending = undef;
        $status = 'expired';
        return;
    }
    my $epoch = $generation;
    Plugins::Twitch::HTTP::form(AUTH_URL . 'token', {
        client_id => $pending->{client_id}, device_code => $pending->{device_code},
        grant_type => 'urn:ietf:params:oauth:grant-type:device_code', scopes => SCOPE,
    }, sub {
        my ($data, $error) = @_;
        return if $epoch != $generation || !$pending;
        if ($error) {
            my $code = $error->{code} || '';
            if ($code eq 'slow_down') {
                $pending->{interval} += 5;
            } elsif (($error->{status} || 0) == 429) {
                $pending->{interval} += 5;
            } elsif ($code ne 'authorization_pending'
                && ($error->{status} || 0) && $error->{status} < 500 && $error->{status} != 429) {
                $status = $code eq 'access_denied' ? 'denied' : 'expired';
                $pending = undef;
                return;
            }
            return _schedule_poll();
        }
        my $client_id = $pending->{client_id};
        $pending = undef;
        unless (_store_tokens($data, $client_id)) {
            return;
        }
        with_token(sub {});
    });
}

sub _store_tokens {
    my ($data, $client_id) = @_;
    unless ($data->{access_token} && $data->{refresh_token}
        && ($data->{expires_in} || 0) > 0) {
        $status = 'error';
        return;
    }
    my $next = {
        %$session, client_id => $client_id,
        access_token => $data->{access_token}, refresh_token => $data->{refresh_token},
        expires_at => time() + $data->{expires_in}, validated_at => 0,
    };
    unless (_persist($next)) {
        # A rotating refresh token has already been consumed. Never retry the
        # old one after a disk error; require a new login instead.
        $session = {};
        ++$generation;
        $status = 'storage_error';
        return;
    }
    $session = $next;
    $retry_after = 0;
    return 1;
}

# Serialize validation and refresh, including concurrent 401 responses. Public
# client refresh tokens rotate and must never be redeemed twice in parallel.
sub with_token {
    my ($callback, $rejected_token) = @_;
    return $callback->(undef, _error()) unless connected();
    return $callback->(undef, _error('Twitch authentication temporarily unavailable'))
        if time() < $retry_after;
    push @waiters, $callback;
    return if $busy;
    $busy = 1;
    if (($rejected_token && $rejected_token eq $session->{access_token})
        || time() >= ($session->{expires_at} || 0) - 60) {
        return _refresh();
    }
    return _validate() if time() >= ($session->{validated_at} || 0) + 3600;
    _finish($session);
}

sub _finish {
    my ($data, $error) = @_;
    my @callbacks = @waiters;
    @waiters = ();
    $busy = 0;
    my $epoch = $generation;
    for my $callback (@callbacks) {
        $callback->($epoch == $generation ? ($data, $error)
            : (undef, _error('Twitch session changed')));
    }
}

sub _unavailable {
    $session->{validated_at} = 0;
    $retry_after = time() + 60;
    $status = 'unavailable';
    _finish(undef, _error('Twitch authentication temporarily unavailable'));
}

sub _invalidate {
    $session = {};
    ++$generation;
    $status = _persist({}) ? 'expired' : 'storage_error';
    _finish(undef, _error());
}

sub _refresh {
    return _invalidate() unless $session->{refresh_token};
    my $epoch = $generation;
    Plugins::Twitch::HTTP::form(AUTH_URL . 'token', {
        client_id => $session->{client_id}, refresh_token => $session->{refresh_token},
        grant_type => 'refresh_token',
    }, sub {
        my ($data, $error) = @_;
        return if $epoch != $generation;
        if ($error) {
            return _invalidate() if ($error->{status} || 0) == 400 || ($error->{status} || 0) == 401;
            return _unavailable();
        }
        unless (_store_tokens($data, $session->{client_id})) {
            _finish(undef, _error('Cannot store Twitch credentials'));
            return;
        }
        _validate();
    });
}

sub _validate {
    my $epoch = $generation;
    Plugins::Twitch::HTTP::request('GET', AUTH_URL . 'validate', {
        Authorization => 'OAuth ' . $session->{access_token},
    }, undef, sub {
        my ($data, $error) = @_;
        return if $epoch != $generation;
        if ($error) {
            return _invalidate() if ($error->{status} || 0) == 401;
            return _unavailable();
        }
        unless (($data->{client_id} || '') eq $session->{client_id}
            && $data->{user_id} && ($data->{expires_in} || 0) > 0 && ref $data->{scopes} eq 'ARRAY'
            && grep { $_ eq SCOPE } @{ $data->{scopes} }) {
            return _invalidate();
        }
        $session->{user_id} = $data->{user_id};
        $session->{login} = $data->{login};
        $session->{validated_at} = time();
        $session->{expires_at} = time() + ($data->{expires_in} || 0);
        $status = 'connected';
        $retry_after = 0;
        _finish($session);
    });
}

sub _schedule_tick {
    Slim::Utils::Timers::killTimers($timer_owner, \&_tick);
    Slim::Utils::Timers::setTimer($timer_owner, time() + 60, \&_tick);
}

sub _tick {
    _schedule_tick();
    with_token(sub {}) if connected();
}

1;
