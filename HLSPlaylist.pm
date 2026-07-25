package Plugins::Twitch::HLSPlaylist;

# LMS must parse an HLS playlist once in order to create a playable remote
# track.  The track is then rewritten to the private twitchhls: protocol,
# whose handler performs all further playlist polling itself.

use strict;
use warnings;

use base qw(Slim::Formats::Playlists::Base);

use Slim::Music::Info;
use URI;

sub _stream_url {
    my ($url) = @_;
    $url =~ s{^https:}{twitchhls:};
    $url =~ s{^http:}{twitchhls:};
    return "$url|";
}

sub read {
    my ($class, $file, undef, $url) = @_;
    local $/;
    my $body = <$file>;
    return unless defined $body && $body =~ /#EXTM3U/;

    my @lines = grep { length } map {
        s/^\s+|\s+$//gr
    } split /\r?\n/, $body;

    # Twitch normally provides an audio media playlist directly.  Supporting
    # a master playlist as well makes the handler robust if Twitch changes
    # that response in the future.
    my $target = $url;
    for (my $i = 0; $i < @lines; $i++) {
        next unless $lines[$i] =~ /^#EXT-X-STREAM-INF:/;
        for my $candidate (@lines[$i + 1 .. $#lines]) {
            next if $candidate =~ /^#/ || !$candidate;
            $target = URI->new_abs($candidate, $url)->as_string;
            last;
        }
        last;
    }

    my $stream_url = _stream_url($target);
    return unless $class->playlistEntryIsValid($stream_url, $url);

    my $title = Slim::Music::Info::title($url) || 'Twitch';
    return $class->_updateMetaData(
        $stream_url,
        { TITLE => $title, CT => 'aac' },
        $url,
    );
}

1;
