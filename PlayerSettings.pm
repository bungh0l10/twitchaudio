package Plugins::Twitch::PlayerSettings;

use strict;
use warnings;
use parent qw(Slim::Web::Settings);
use Slim::Web::HTTP::CSRF;
use Slim::Utils::Prefs qw(preferences);
use Slim::Utils::Strings qw(string);
use Plugins::Twitch::Config ();
use Plugins::Twitch::OAuth ();
use Plugins::Twitch::Settings ();

my $prefs = preferences('plugin.twitch');
sub name { Slim::Web::HTTP::CSRF->protectName('PLUGIN_TWITCH_NAME') }
sub needsClient { return 1; }
sub page { Slim::Web::HTTP::CSRF->protectURI('plugins/twitch/settings/player.html') }
sub prefs {
    my ($class, $client) = @_;
    return unless $client;
    Plugins::Twitch::Config::initialize_player($client);
    return ($prefs->client($client), qw(oauth_account metadata_source show_local_channels show_followed show_followed_live use_personal_channels));
}
sub beforeRender {
    my ($class, $params, $client) = @_;
    Plugins::Twitch::Settings->beforeRender($params);
    # Server beforeRender populates account choices; preserve this player's own
    # selection, including an explicit anonymous choice and inheritance.
    $params->{prefs}{pref_oauth_account} = $prefs->client($client)->get('oauth_account') if $client;
    my $account = Plugins::Twitch::Config::account_id($client);
    my $state = Plugins::Twitch::OAuth::state($account);
    $params->{twitch_effective_name} = string('PLUGIN_TWITCH_NO_ACCOUNT');
    for my $a (@{ $params->{twitch_accounts} }) {
        $params->{twitch_effective_name} = $a->{display_name} if $a->{id} eq $account;
    }
    $params->{twitch_effective_status_key} = 'PLUGIN_TWITCH_AUTH_' . uc($state->{status});
    $params->{twitch_effective_helix} = Plugins::Twitch::Config::helix_metadata($client) && $state->{connected};
    $params->{twitch_helix_available} = $state->{connected};
    $params->{twitch_server_helix} = Plugins::Twitch::Config::helix_metadata();
    for my $menu (@{ $params->{twitch_menus} }) {
        $menu->{server_visible} = Plugins::Twitch::Config::menu_visible($menu->{key});
    }
}

sub handler {
    my ($class, $client, $params, @args) = @_;
    if ($client && $params->{saveSettings}) {
        Plugins::Twitch::Config::initialize_player($client);
        # Disabled form controls are not submitted. Preserve their configured
        # values so saving local options never resets account-specific choices.
        for my $key (qw(metadata_source show_followed show_followed_live)) {
            $params->{'pref_' . $key} = $prefs->client($client)->get($key)
                unless defined $params->{'pref_' . $key};
        }
    }
    return $class->SUPER::handler($client, $params, @args);
}

1;
