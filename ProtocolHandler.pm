package Plugins::TwitchAudio::ProtocolHandler;

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Log;
use Slim::Utils::Scanner::Remote;
use Plugins::TwitchAudio::Twitch;

my $log = Slim::Utils::Log->logger('plugin.twitchaudio');

# scanUrl: wandelt twitch://channel in ein spielbares Song-Objekt
sub scanUrl {
    my ($class, $uri, $args) = @_;
    my ($channel) = $uri =~ m|twitch://(.+)|;

    $log->debug("scanUrl called for channel: $channel");

    # erst Kanalinfo holen
    Plugins::TwitchAudio::Twitch::getChannel($channel, sub {
        my ($data) = @_;
        my $user   = $data->{user} if $data;
        my $online = $user && $user->{stream} ? 1 : 0;

        my $title  = $online ? $user->{stream}{title} : "Offline";
        my $cover  = $user ? $user->{profileImageURL} : "";
        my $artist = $user ? $user->{login} : $channel;

        my $url;
        if ($online) {
            $url = Plugins::TwitchAudio::Twitch::getAudioUrl($artist);
        }

        unless ($url) {
            $log->warn("No audio stream available for $artist");
            return;
        }

        # Song direkt an Scanner übergeben
        my $song = {
            url    => $url,
            type   => 'audio',
            artist => $artist,
            title  => $title,
            cover  => $cover,
        };

        # Scanner absetzen, Player bekommt die Metadaten korrekt
        Slim::Utils::Scanner::Remote->scanURL($url, { %$args, song => $song });

        # Plugin-Daten für Player/Skins setzen
        my $client = $args->{client};
        if ($client && $client->playingSong) {
            $client->playingSong->pluginData({
                artist => $artist,
                title  => $title,
                cover  => $cover,
            });
            Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
        }
    });
}

1;