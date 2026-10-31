package Plugins::Twitch::Settings;

use strict;
use warnings;
use parent qw(Slim::Web::Settings);
use Slim::Web::HTTP::CSRF;
use Slim::Utils::Prefs qw(preferences);
use Slim::Utils::Strings qw(string);
use Plugins::Twitch::Config ();
use Plugins::Twitch::OAuth ();

my $prefs = preferences('plugin.twitch');
my @fields = qw(oauth_client_id oauth_account helix_metadata show_local_channels show_followed show_followed_live);
sub name { Slim::Web::HTTP::CSRF->protectName('PLUGIN_TWITCH_NAME') }
sub page { Slim::Web::HTTP::CSRF->protectURI('plugins/twitch/settings/basic.html') }
sub prefs { return ($prefs, @fields); }

sub handler {
    my ($class, $client, $params, $callback, @args) = @_;
    if ($params->{saveSettings}) {
        my $id = $params->{pref_oauth_client_id} // $prefs->get('oauth_client_id') // '';
        $id =~ s/^\s+|\s+$//g;
        $params->{pref_oauth_client_id} = $id;
        my (undef, $valid) = $prefs->set('oauth_client_id', $id);
        delete $params->{saveSettings};
        $params->{warning} = string('PLUGIN_TWITCH_CLIENT_ID_REQUIRED') unless $valid;
        for my $field (@fields[1 .. $#fields]) {
            next unless defined $params->{'pref_' . $field};
            my $value = $params->{'pref_' . $field};
            if ($field eq 'oauth_account') {
                $value = 'none' unless $value eq 'none' || Plugins::Twitch::OAuth::exists_account($value);
            } else {
                $value = $value eq '1' ? 1 : 0;
            }
            $prefs->set($field, $value);
        }
        my ($action, $account) = ($params->{twitch_action} || '') =~ /^(connect|disconnect|delete|default):(default|a[0-9]+)$/;
        if ($params->{twitch_add}) {
            if ($valid && $id) {
                $account = Plugins::Twitch::OAuth::add_account();
                $action = 'connect' if $account;
                $params->{warning} = string('PLUGIN_TWITCH_AUTH_STORAGE_ERROR') unless $account;
            } else {
                $params->{warning} = string('PLUGIN_TWITCH_CLIENT_ID_REQUIRED');
            }
        }
        # Continue accepting the old form's single-account actions during upgrades.
        if ($params->{twitch_connect}) { $action = 'connect'; }
        if ($params->{twitch_disconnect}) { $action = 'disconnect'; }
        if ($action && $valid) {
            if ($action eq 'connect') {
                if (!$id) {
                    $params->{warning} = string('PLUGIN_TWITCH_CLIENT_ID_REQUIRED');
                } elsif (!defined $account || Plugins::Twitch::OAuth::exists_account($account)) {
                    Plugins::Twitch::OAuth::start(sub {
                        my (undef, $error) = @_;
                        $params->{warning} = string('PLUGIN_TWITCH_AUTH_ERROR') if $error;
                        my $rendered = $class->SUPER::handler($client, $params);
                        $callback->($client, $params, $rendered, @args) if $callback;
                    }, $account);
                    return;
                }
            } elsif ($action eq 'disconnect') {
                Plugins::Twitch::OAuth::disconnect($account);
            } elsif ($action eq 'delete') {
                $params->{warning} = string('PLUGIN_TWITCH_AUTH_STORAGE_ERROR')
                    unless Plugins::Twitch::OAuth::delete_account($account);
            } elsif (Plugins::Twitch::OAuth::exists_account($account)) {
                $prefs->set('oauth_account', $account);
            }
        }
    }
    return $class->SUPER::handler($client, $params);
}

sub beforeRender {
    my ($class, $params) = @_;
    my $accounts = Plugins::Twitch::OAuth::accounts();
    my $selected = Plugins::Twitch::Config::account_id();
    for my $a (@$accounts) {
        $a->{status_key} = 'PLUGIN_TWITCH_AUTH_' . uc($a->{status});
        $a->{is_default} = $a->{id} eq $selected;
        $a->{display_name} = $a->{login} || string($a->{status_key});
        $params->{twitch_polling} = 1 if $a->{status} =~ /^(pending|checking|starting)$/;
    }
    $params->{twitch_accounts} = $accounts;
    $params->{twitch_auth} = Plugins::Twitch::OAuth::state();
    $params->{twitch_helix_available} = Plugins::Twitch::OAuth::connected($selected);
    $params->{twitch_effective_helix} = $params->{twitch_helix_available}
        && Plugins::Twitch::Config::helix_metadata();
    $params->{twitch_auth_status_key} = 'PLUGIN_TWITCH_AUTH_' . uc($params->{twitch_auth}{status});
    $params->{twitch_default_name} = string('PLUGIN_TWITCH_NO_ACCOUNT');
    for my $a (@$accounts) { $params->{twitch_default_name} = $a->{display_name} if $a->{is_default}; }
    $params->{twitch_menus} = [map { +{key => $_->[0], title => $_->[1], requires_account => $_->[0] ne 'show_local_channels'} } (
        ['show_local_channels', 'PLUGIN_TWITCH_MY_CHANNELS'],
        ['show_followed', 'PLUGIN_TWITCH_FOLLOWED'],
        ['show_followed_live', 'PLUGIN_TWITCH_FOLLOWED_LIVE'],
    )];
    # The initial unset value has the same visual meaning as anonymous use.
    $params->{prefs}{pref_oauth_account} = $selected;
    delete $params->{twitch_polling} unless grep { $_->{status} =~ /^(pending|checking|starting)$/ } @$accounts;
}

1;
