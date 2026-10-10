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

my %accounts;
my $sequence = 0;
my $instance = 0;
sub _next_instance { ++$instance }

sub _error { return { type => 'auth', message => $_[0] || 'Twitch login required' }; }
sub _file { File::Spec->catfile(Slim::Utils::Prefs::dir(), 'twitch-oauth.json') }

# A single atomic credentials file contains all sessions, outside LMS's public
# preference API. Never put tokens into account lists or player preferences.
sub _persist {
    my ($value) = @_;
    my ($fh, $path);
    my $ok = eval {
        ($fh, $path) = tempfile('twitch-oauth-XXXXXX', DIR => Slim::Utils::Prefs::dir(), UNLINK => 0);
        binmode $fh;
        print {$fh} encode_json($value) or die 'write';
        close $fh or die 'close';
        rename $path, _file() or die 'rename';
        1;
    };
    unlink $path if !$ok && $path && -e $path;
    return $ok;
}

sub _save_record {
    my ($id, $session) = @_;
    return unless $accounts{$id};
    my %stored = map {
        $_ => { session => $_ eq $id ? $session : $accounts{$_}{session} }
    } keys %accounts;
    return _persist({version => 2, accounts => \%stored});
}

sub _set_initial_default {
    my ($id) = @_;
    my $prefs = preferences('plugin.twitch');
    $prefs->set('oauth_account', $id) unless length($prefs->get('oauth_account') || '');
}

sub init {
    Plugins::Twitch::OAuth::shutdown();
    %accounts = ();
    my $stored;
    if (open my $fh, '<', _file()) {
        local $/;
        $stored = eval { decode_json(<$fh>) };
        close $fh;
    }
    my $migrating = ref $stored eq 'HASH' && $stored->{access_token};
    $stored = {accounts => {default => {session => $stored}}} if $migrating;
    if (ref $stored eq 'HASH' && ref $stored->{accounts} eq 'HASH') {
        for my $id (keys %{ $stored->{accounts} }) {
            next unless $id =~ /^(?:default|a[0-9]+)$/;
            my $record = $stored->{accounts}{$id};
            next unless ref $record eq 'HASH' && ref $record->{session} eq 'HASH';
            my $session = $record->{session};
            $session = {map { $_ => $session->{$_} } qw(user_id login)}
                if ($session->{client_id} || '') ne Plugins::Twitch::Config::oauth_client_id();
            $accounts{$id} = Plugins::Twitch::OAuth::Account->new($id, $session);
        }
    }
    if ($migrating && $accounts{default}) {
        _save_record('default', $accounts{default}{session});
        _set_initial_default('default');
    }
    # Start after all records are present so an asynchronous validation cannot
    # overwrite accounts which have not yet been loaded.
    $_->_tick() for values %accounts;
}

sub shutdown { $_->shutdown() for values %accounts; }
sub disconnect_all { $_->disconnect() for values %accounts; }
sub _id { return defined $_[0] ? $_[0] : Plugins::Twitch::Config::account_id(); }
sub exists_account { my ($id) = @_; return defined $id && exists $accounts{$id}; }
sub connected { my $a = $accounts{_id($_[0])}; return $a ? $a->connected() : 0; }
sub session_key {
    my $id = _id($_[0]);
    return $id . ':' . ($accounts{$id} ? $accounts{$id}->session_key() : 'missing');
}
sub state {
    my $id = _id($_[0]);
    return $accounts{$id} ? $accounts{$id}->state()
        : {id => $id, status => 'disconnected', connected => 0, login => '', user_code => '', verification_uri => ''};
}
sub accounts {
    return [map { +{ %{$_->state()},
        players => Plugins::Twitch::Config::account_players($_->{id}) } }
        sort { ($a->{session}{login} || $a->{id}) cmp ($b->{session}{login} || $b->{id}) }
        values %accounts];
}
sub add_account {
    my $id;
    do { $id = 'a' . time() . ++$sequence; } while exists $accounts{$id};
    $accounts{$id} = Plugins::Twitch::OAuth::Account->new($id, {});
    unless (_save_record($id, {})) { delete $accounts{$id}; return; }
    return $id;
}
sub disconnect { my $a = $accounts{_id($_[0])}; $a->disconnect() if $a; }
sub delete_account {
    my ($id) = @_;
    return unless exists_account($id);
    my $a = $accounts{$id};
    $a->disconnect();
    delete $accounts{$id};
    my %stored = map { $_ => {session => $accounts{$_}{session}} } keys %accounts;
    unless (_persist({version => 2, accounts => \%stored})) {
        $accounts{$id} = $a;
        $a->{status} = 'storage_error';
        return;
    }
    $a->shutdown();
    Plugins::Twitch::Config::remove_account_references($id);
    return 1;
}
sub start {
    my ($callback, $id) = @_;
    # Compatibility for the former single-account entry point.
    unless (defined $id) {
        $id = Plugins::Twitch::Config::account_id();
        $id = 'default' if $id eq 'none';
        $accounts{$id} ||= Plugins::Twitch::OAuth::Account->new($id, {});
        _set_initial_default($id);
    }
    return $callback->(undef, _error('Unknown Twitch account')) unless exists_account($id);
    $accounts{$id}->start($callback);
}
sub with_token {
    my ($callback, $rejected, $id) = @_;
    my $a = $accounts{_id($id)};
    return $callback->(undef, _error()) unless $a;
    $a->with_token($callback, $rejected);
}
# Common timer functions retain a separate owner for each account.
sub _poll { my $a = ref $_[0] ? $_[0] : $accounts{_id()}; $a->_poll() if $a; }
sub _tick { my $a = ref $_[0] ? $_[0] : $accounts{_id()}; $a->_tick() if $a; }

package Plugins::Twitch::OAuth::Account;

use strict;
use warnings;
use constant AUTH_URL => 'https://id.twitch.tv/oauth2/';
use constant SCOPE => 'user:read:follows';
sub _error { Plugins::Twitch::OAuth::_error(@_) }
sub new {
    my ($class, $id, $session) = @_;
    $session->{validated_at} = 0;
    return bless {id => $id, session => $session,
        instance => Plugins::Twitch::OAuth::_next_instance(), generation => 0, waiters => [], busy => 0, retry_after => 0,
        status => $session->{access_token} ? 'checking' : 'disconnected'}, $class;
}

sub shutdown {
    my $self = shift;
    ++$self->{generation};
    Slim::Utils::Timers::killTimers($self, \&Plugins::Twitch::OAuth::_tick);
    Slim::Utils::Timers::killTimers($self, \&Plugins::Twitch::OAuth::_poll);
    $self->{pending} = undef;
    $self->_finish(undef, _error('Twitch session changed'));
}

sub connected {
    my $self = shift;
    return $self->{session}->{access_token}
        && ($self->{session}->{client_id} || '') eq Plugins::Twitch::Config::oauth_client_id() ? 1 : 0;
}

sub session_key { my $self = shift; return $self->{instance} . ':' . $self->{generation} . ':' . ($self->{session}->{user_id} || ''); }

sub state {
    my $self = shift;
    return {
        status => $self->{status},
        connected => $self->connected(),
        id => $self->{id},
        login => $self->{session}->{login} || '',
        user_code => $self->{pending} ? $self->{pending}->{user_code} : '',
        verification_uri => $self->{pending} ? $self->{pending}->{verification_uri} : '',
    };
}

sub disconnect {
    my $self = shift;
    my $old = $self->{session};
    $self->{session} = { map { $_ => $self->{session}{$_} } qw(user_id login) };
    $self->shutdown();
    $self->{retry_after} = 0;
    $self->{status} = Plugins::Twitch::OAuth::_save_record($self->{id}, $self->{session}) ? 'disconnected' : 'storage_error';
    if ($old->{access_token} && $old->{client_id}) {
        Plugins::Twitch::HTTP::form(AUTH_URL . 'revoke', {
            client_id => $old->{client_id}, token => $old->{access_token},
        }, sub {});
    }
    $self->_schedule_tick();
}

sub start {
    my $self = shift;
    my ($callback) = @_;
    my $client_id = Plugins::Twitch::Config::oauth_client_id();
    return $callback->(undef, _error('Missing Twitch client ID')) unless $client_id;
    $self->disconnect();
    my $epoch = $self->{generation};
    $self->{status} = 'starting';
    Plugins::Twitch::HTTP::form(AUTH_URL . 'device', {
        client_id => $client_id, scopes => SCOPE,
    }, sub {
        my ($data, $error) = @_;
        return $callback->(undef, _error('Twitch session changed')) if $epoch != $self->{generation};
        unless (!$error && $data->{device_code} && $data->{user_code}
            && ($data->{expires_in} || 0) > 0
            && ($data->{verification_uri} || '') =~ m{^https://(?:www\.)?twitch\.tv/activate(?:[/?]|$)}) {
            $self->{status} = 'error';
            return $callback->(undef, _error('Unable to start Twitch login'));
        }
        $self->{pending} = {
            %$data, client_id => $client_id,
            expires_at => time() + $data->{expires_in},
            interval => ($data->{interval} || 5) < 5 ? 5 : ($data->{interval} || 5),
        };
        $self->{status} = 'pending';
        $self->_schedule_poll();
        return $callback->($self->state());
    });
}

sub _schedule_poll {
    my $self = shift;
    Slim::Utils::Timers::killTimers($self, \&Plugins::Twitch::OAuth::_poll);
    Slim::Utils::Timers::setTimer($self, time() + $self->{pending}->{interval}, \&Plugins::Twitch::OAuth::_poll)
        if $self->{pending};
}

sub _poll {
    my $self = shift;
    return unless $self->{pending};
    if (time() >= $self->{pending}->{expires_at}) {
        $self->{pending} = undef;
        $self->{status} = 'expired';
        return;
    }
    my $epoch = $self->{generation};
    Plugins::Twitch::HTTP::form(AUTH_URL . 'token', {
        client_id => $self->{pending}->{client_id}, device_code => $self->{pending}->{device_code},
        grant_type => 'urn:ietf:params:oauth:grant-type:device_code', scopes => SCOPE,
    }, sub {
        my ($data, $error) = @_;
        return if $epoch != $self->{generation} || !$self->{pending};
        if ($error) {
            my $code = $error->{code} || '';
            if ($code eq 'slow_down') {
                $self->{pending}->{interval} += 5;
            } elsif (($error->{status} || 0) == 429) {
                $self->{pending}->{interval} += 5;
            } elsif ($code ne 'authorization_pending'
                && ($error->{status} || 0) && $error->{status} < 500 && $error->{status} != 429) {
                $self->{status} = $code eq 'access_denied' ? 'denied' : 'expired';
                $self->{pending} = undef;
                return;
            }
            return $self->_schedule_poll();
        }
        my $client_id = $self->{pending}->{client_id};
        $self->{pending} = undef;
        unless ($self->_store_tokens($data, $client_id)) {
            return;
        }
        $self->with_token(sub {});
    });
}

sub _store_tokens {
    my $self = shift;
    my ($data, $client_id) = @_;
    unless ($data->{access_token} && $data->{refresh_token}
        && ($data->{expires_in} || 0) > 0) {
        $self->{status} = 'error';
        return;
    }
    my $next = {
        %{ $self->{session} }, client_id => $client_id,
        access_token => $data->{access_token}, refresh_token => $data->{refresh_token},
        expires_at => time() + $data->{expires_in}, validated_at => 0,
    };
    unless (Plugins::Twitch::OAuth::_save_record($self->{id}, $next)) {
        # A rotating refresh token has already been consumed. Never retry the
        # old one after a disk error; require a new login instead.
        $self->{session} = { map { $_ => $self->{session}{$_} } qw(user_id login) };
        ++$self->{generation};
        $self->{status} = 'storage_error';
        return;
    }
    $self->{session} = $next;
    $self->{retry_after} = 0;
    return 1;
}

# Serialize validation and refresh, including concurrent 401 responses. Public
# client refresh tokens rotate and must never be redeemed twice in parallel.
sub with_token {
    my $self = shift;
    my ($callback, $rejected_token) = @_;
    return $callback->(undef, _error()) unless $self->connected();
    return $callback->(undef, _error('Twitch authentication temporarily unavailable'))
        if time() < $self->{retry_after};
    push @{ $self->{waiters} }, $callback;
    return if $self->{busy};
    $self->{busy} = 1;
    if (($rejected_token && $rejected_token eq $self->{session}->{access_token})
        || time() >= ($self->{session}->{expires_at} || 0) - 60) {
        return $self->_refresh();
    }
    return $self->_validate() if time() >= ($self->{session}->{validated_at} || 0) + 3600;
    $self->_finish($self->{session});
}

sub _finish {
    my $self = shift;
    my ($data, $error) = @_;
    my @callbacks = @{ $self->{waiters} };
    @{ $self->{waiters} } = ();
    $self->{busy} = 0;
    my $epoch = $self->{generation};
    for my $callback (@callbacks) {
        $callback->($epoch == $self->{generation} ? ($data, $error)
            : (undef, _error('Twitch session changed')));
    }
}

sub _unavailable {
    my $self = shift;
    $self->{session}->{validated_at} = 0;
    $self->{retry_after} = time() + 60;
    $self->{status} = 'unavailable';
    $self->_finish(undef, _error('Twitch authentication temporarily unavailable'));
}

sub _invalidate {
    my $self = shift;
    $self->{session} = { map { $_ => $self->{session}{$_} } qw(user_id login) };
    ++$self->{generation};
    $self->{status} = Plugins::Twitch::OAuth::_save_record($self->{id}, $self->{session}) ? 'expired' : 'storage_error';
    $self->_finish(undef, _error());
}

sub _refresh {
    my $self = shift;
    return $self->_invalidate() unless $self->{session}->{refresh_token};
    my $epoch = $self->{generation};
    Plugins::Twitch::HTTP::form(AUTH_URL . 'token', {
        client_id => $self->{session}->{client_id}, refresh_token => $self->{session}->{refresh_token},
        grant_type => 'refresh_token',
    }, sub {
        my ($data, $error) = @_;
        return if $epoch != $self->{generation};
        if ($error) {
            return $self->_invalidate() if ($error->{status} || 0) == 400 || ($error->{status} || 0) == 401;
            return $self->_unavailable();
        }
        unless ($self->_store_tokens($data, $self->{session}->{client_id})) {
            $self->_finish(undef, _error('Cannot store Twitch credentials'));
            return;
        }
        $self->_validate();
    });
}

sub _validate {
    my $self = shift;
    my $epoch = $self->{generation};
    Plugins::Twitch::HTTP::request('GET', AUTH_URL . 'validate', {
        Authorization => 'OAuth ' . $self->{session}->{access_token},
    }, undef, sub {
        my ($data, $error) = @_;
        return if $epoch != $self->{generation};
        if ($error) {
            return $self->_invalidate() if ($error->{status} || 0) == 401;
            return $self->_unavailable();
        }
        unless (($data->{client_id} || '') eq $self->{session}->{client_id}
            && $data->{user_id} && ($data->{expires_in} || 0) > 0 && ref $data->{scopes} eq 'ARRAY'
            && grep { $_ eq SCOPE } @{ $data->{scopes} }) {
            return $self->_invalidate();
        }
        if ($self->{session}{user_id} && $self->{session}{user_id} ne $data->{user_id}) {
            $self->_invalidate();
            $self->{status} = 'wrong_account' unless $self->{status} eq 'storage_error';
            return;
        }
        $self->{session}->{user_id} = $data->{user_id};
        $self->{session}->{login} = $data->{login};
        $self->{session}->{validated_at} = time();
        $self->{session}->{expires_at} = time() + ($data->{expires_in} || 0);
        $self->{status} = 'connected';
        $self->{retry_after} = 0;
        unless (Plugins::Twitch::OAuth::_save_record($self->{id}, $self->{session})) {
            $self->_invalidate();
            $self->{status} = 'storage_error';
            return;
        }
        Plugins::Twitch::OAuth::_set_initial_default($self->{id});
        $self->_finish($self->{session});
    });
}

sub _schedule_tick {
    my $self = shift;
    Slim::Utils::Timers::killTimers($self, \&Plugins::Twitch::OAuth::_tick);
    Slim::Utils::Timers::setTimer($self, time() + 60, \&Plugins::Twitch::OAuth::_tick);
}

sub _tick {
    my $self = shift;
    $self->_schedule_tick();
    $self->with_token(sub {}) if $self->connected();
}

1;
