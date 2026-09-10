package Plugins::Twitch::PlayerSettings;

use strict;
use warnings;

use parent qw(Slim::Web::Settings);
use Slim::Web::HTTP::CSRF;
use Slim::Utils::Prefs qw(preferences);

my $prefs = preferences('plugin.twitch');

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_TWITCH_NAME');
}

sub needsClient { return 1; }

sub page {
    return Slim::Web::HTTP::CSRF->protectURI('plugins/twitch/settings/player.html');
}

sub prefs {
    my ($class, $client) = @_;
    return unless $client;
    return ($prefs->client($client), qw(use_personal_channels));
}

1;
