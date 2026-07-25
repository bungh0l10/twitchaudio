package Plugins::Twitch::HLSStream;

# LMS protocol adapter for native Twitch HLS audio. Playlist parsing,
# networking, buffering and container extraction live in HLS::Session.

use strict;
use warnings;
use bytes;

use base qw(IO::Handle);

use Slim::Player::ProtocolHandlers;
use Slim::Control::Request ();
use Slim::Utils::Errno;
use Slim::Utils::Log qw(logger);
use Slim::Utils::Versions ();
use Time::HiRes qw(time);

use Plugins::Twitch::HLS::Session ();

my $log = logger('plugin.twitch');

Slim::Player::ProtocolHandlers->registerHandler('twitchhls', __PACKAGE__);

# LMS releases before 7.9.1 retry an IO handler only for EINTR. Newer LMS
# releases correctly use EWOULDBLOCK for an asynchronously filled handle.
use constant IO_SELECT_FIXED =>
    Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0;

sub isRemote         { 1 }
sub isAudio          { 1 }
sub canDirectStream  { 0 }
sub contentType      { 'audio/aac' }
sub formatOverride   { 'aac' }

sub canSeek {
    my ($class, $client, $song) = @_;
    return $song && $song->duration ? 1 : 0;
}

sub getSeekData {
    my ($class, $client, $song, $newtime) = @_;
    return { timeOffset => $newtime };
}

sub _set_progress_offset {
    my ($song, $offset) = @_;
    return unless $song && defined $offset;

    $song->startOffset($offset);

    my $client = $song->master;
    $client->remoteStreamStartTime(time() - $offset)
        if $client && $client->can('remoteStreamStartTime');
}

sub _notify_metadata {
    my ($song) = @_;
    return unless $song && $song->master;
    Slim::Control::Request::notifyFromArray(
        $song->master,
        ['newmetadata'],
    );
}

sub getMetadataFor {
    my ($class, $client, $url) = @_;
    my $song = $client && $client->playingSong or return {};
    $song->currentTrack or return {};

    my $meta = $song->pluginData('wmaMeta') || {};
    my $bitrate = $song->bitrate
        ? sprintf('%dkbps', int(($song->bitrate + 500) / 1000))
        : undef;
    my $type = 'AAC (Twitch)';

    return {
        title        => $meta->{title},
        artist       => $meta->{artist},
        cover        => $meta->{cover},
        icon         => $meta->{cover},
        duration     => $song->duration || undef,
        bitrate      => $bitrate,
        type         => $type,
        originalType => $type,
        originaltype => $type,
        url          => $url,
    };
}

# Prevent LMS' generic remote scanner from interpreting media playlists as
# ordinary M3U playlists containing directly playable files.
sub scanStream {
    my ($class, $url, $track, $args) = @_;

    $track->content_type('aac');
    $track->update;

    if (my $song = $args->{song}) {
        $song->handler($class);
    }

    my $cb = $args->{cb} || sub {};
    return $cb->($track, undef, @{ $args->{pt} || [] });
}

sub new {
    my ($class, $args) = @_;
    my $song = $args->{song};
    my $url = ($song && $song->can('streamUrl') ? $song->streamUrl : undef)
        || $args->{url};
    $url =~ s{^twitchhls:}{https:};
    $url =~ s/\|$//;

    my $seek_time = ($song && $song->seekdata)
        ? $song->seekdata->{timeOffset}
        : undef;

    _set_progress_offset($song, $seek_time)
        if defined $seek_time && $seek_time > 0;

    my $self = $class->SUPER::new;
    ${*$self}{song} = $song;
    ${*$self}{session} = Plugins::Twitch::HLS::Session->new({
        playlist_url => $url,
        seek_time    => $seek_time,
        log          => $log,
        on_duration  => sub {
            my ($duration) = @_;
            return unless $song && $duration;
            return if $song->duration
                && abs($song->duration - $duration) < 0.01;
            $song->duration($duration);
            _notify_metadata($song);
        },
        on_bitrate => sub {
            my ($bitrate) = @_;
            return unless $song && $bitrate && !$song->bitrate;
            $song->bitrate($bitrate);
            _notify_metadata($song);
        },
        on_seek => sub {
            my ($offset) = @_;
            _set_progress_offset($song, $offset);
        },
    });

    $log->info('Twitch HLS reader opened');
    $log->debug("Twitch HLS playlist URL: $url");
    return $self;
}

sub close {
    my ($self) = @_;
    ${*$self}{closed} = 1;
    ${*$self}{session}->close if ${*$self}{session};
    delete ${*$self}{session};
    return;
}

sub sysread {
    my ($self, undef, $max_bytes) = @_;
    return 0 if ${*$self}{closed};

    my $bytes = ${*$self}{session}->read($max_bytes);
    if (defined $bytes) {
        $_[1] = $bytes;
        return length($bytes);
    }

    $! = IO_SELECT_FIXED ? EWOULDBLOCK : EINTR;
    return undef;
}

1;
