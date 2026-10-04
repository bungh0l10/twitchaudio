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

sub name { Slim::Web::HTTP::CSRF->protectName('PLUGIN_TWITCH_NAME') }
sub page { Slim::Web::HTTP::CSRF->protectURI('plugins/twitch/settings/basic.html') }
sub prefs { return ($prefs, qw(oauth_client_id helix_metadata)); }

sub handler {
    my ($class, $client, $params, $callback, @args) = @_;
    if ($params->{saveSettings}) {
        $params->{pref_helix_metadata} = $params->{pref_helix_metadata} ? 1 : 0;
        my $id = $params->{pref_oauth_client_id} // '';
        $id =~ s/^\s+|\s+$//g;
        $params->{pref_oauth_client_id} = $id;
        # Store the ID before starting the async device authorization request.
        my (undef, $valid) = $prefs->set('oauth_client_id', $id);
        if ($valid && $params->{twitch_disconnect}) {
            Plugins::Twitch::OAuth::disconnect();
        } elsif ($valid && $id && $params->{twitch_connect}) {
            $prefs->set('helix_metadata', $params->{pref_helix_metadata});
            # Only render on completion. A late response must not save an old
            # client ID again after another tab has changed/disconnected it.
            delete $params->{saveSettings};
            Plugins::Twitch::OAuth::start(sub {
                $callback->($client, $params, $class->SUPER::handler($client, $params), @args);
            });
            return;
        } elsif ($params->{twitch_connect} && !$id) {
            $params->{warning} = string('PLUGIN_TWITCH_CLIENT_ID_REQUIRED');
        }
    }
    return $class->SUPER::handler($client, $params);
}

sub beforeRender {
    my ($class, $params) = @_;
    $params->{twitch_auth} = Plugins::Twitch::OAuth::state();
    $params->{twitch_auth_status_key} = 'PLUGIN_TWITCH_AUTH_' . uc($params->{twitch_auth}{status});
}

1;
