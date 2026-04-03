package Plugins::TwitchAudio::ProtocolHandler;

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Log;
use Slim::Player::Song;

my $log = Slim::Utils::Log->logger('plugin.twitchaudio');

# scanUrl: baut direkt das Song-Objekt aus den übergebenen Metadaten
sub scanUrl {
    my ($class, $uri, $args) = @_;
    my $client = $args->{client};

    # Die Metadaten werden über $args->{song} übergeben
    my $songData = $args->{song};
    unless ($songData && $songData->{url}) {
        $log->warn("scanUrl: Keine URL für $uri");
        return;
    }

    # Eigenes Song-Objekt bauen
    my $song = Slim::Player::Song->new({
        url    => $songData->{url},
        type   => 'audio',
        name   => $songData->{artist} . ' - ' . $songData->{title},  # Player zeigt Name
        artist => $songData->{artist},
        title  => $songData->{title},
        cover  => $songData->{cover},
    });

    # Song an den Client übergeben
    if ($client) {
        $client->play($song);

        # pluginData setzen (für Skins etc.)
        $client->playingSong->pluginData({
            artist => $songData->{artist},
            title  => $songData->{title},
            cover  => $songData->{cover},
        });

        Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
    }

    $log->debug("scanUrl: Playing $songData->{artist} - $songData->{title}");
}

1;