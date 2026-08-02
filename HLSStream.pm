package Plugins::Twitch::HLSStream;

# LMS protocol adapter for native Twitch HLS audio. Playlist parsing,
# networking, buffering and container extraction live in HLS::Session.

use strict;
use warnings;
use bytes;

use base qw(IO::Handle);

use Slim::Player::ProtocolHandlers;
use Slim::Control::Request ();
use Slim::Utils::Cache;
use Slim::Utils::Errno;
use Slim::Utils::Log qw(logger);
use Slim::Utils::Versions ();
use Time::HiRes qw(time);

use Plugins::Twitch::Config ();
use Plugins::Twitch::HLS::Session ();

my $log = logger('plugin.twitch');

Slim::Player::ProtocolHandlers->registerHandler('twitchhls', __PACKAGE__);

# LMS releases before 7.9.1 retry an IO handler only for EINTR. Newer LMS
# releases correctly use EWOULDBLOCK for an asynchronously filled handle.
use constant IO_SELECT_FIXED =>
    Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0;
use constant RESUME_CACHE_INTERVAL => 3;

sub isRemote         { 1 }
sub isAudio          { 1 }
sub canDirectStream  { 0 }
sub contentType      { 'audio/aac' }
sub formatOverride   { 'aac' }

sub _is_vod_song {
    my ($song) = @_;
    return 0 unless $song;

    my $media_type = $song->pluginData('twitchMediaType');
    return 1 if defined $media_type && $media_type eq 'vod';
    return 0 if defined $media_type && $media_type eq 'live';

    for my $method (qw(track currentTrack)) {
        next unless $song->can($method);
        my $track = $song->$method or next;
        my $url = $track->can('url') ? $track->url : '';
        return 1 if $url =~ /^twitch:vod:/;
        return 0 if $url =~ /^twitch:live:/;
    }

    # Unknown streams must retain live semantics: no duration or progress bar.
    return 0;
}

sub _twitch_media_id {
    my ($song, $url) = @_;
    my @urls = defined $url ? ($url) : ();

    if ($song) {
        for my $method (qw(track currentTrack)) {
            next unless $song->can($method);
            my $track = $song->$method or next;
            push @urls, $track->url if $track->can('url');
        }
    }

    for my $candidate (@urls) {
        next unless defined $candidate;
        return ($1, $2) if $candidate =~ /^twitch:(live|vod):([^|?#]+)/;
        my $mapped = Slim::Utils::Cache->new->get("twitch:media-for-url:$candidate");
        return ($1, $2) if defined $mapped
            && $mapped =~ /^(live|vod):([^|?#]+)/;
    }

    return;
}

sub _restore_cached_metadata {
    my ($song, $url) = @_;
    my ($type, $id) = _twitch_media_id($song, $url);
    my $meta;
    if ($type && $id) {
        $id = lc $id if $type eq 'live';
        $meta = Slim::Utils::Cache->new->get("twitch:$type:$id");
        unless (ref $meta eq 'HASH') {
            my $song_matches_type = $song
                && (($type eq 'vod' && _is_vod_song($song))
                    || ($type eq 'live' && !_is_vod_song($song)));
            $meta = $song->pluginData('wmaMeta') if $song_matches_type;
        }
    } else {
        $meta = $song ? $song->pluginData('wmaMeta') : undef;
    }
    return {} unless ref $meta eq 'HASH';

    if ($song) {
        $song->pluginData('twitchMediaType', $type);
        $song->pluginData('wmaMeta', $meta);
    }
    return $meta;
}

sub _restore_audio_info {
    my ($song, $url) = @_;

    my $audio_info = $song
        ? $song->pluginData('twitchAudioInfo')
        : undef;
    return $audio_info if ref $audio_info eq 'HASH';

    my ($type, $id) = _twitch_media_id($song, $url);
    return unless $type && $id;
    $id = lc $id if $type eq 'live';

    $audio_info = Slim::Utils::Cache->new->get(
        "twitch:audio-info:$type:$id",
    );
    return unless ref $audio_info eq 'HASH';

    $song->pluginData('twitchAudioInfo', $audio_info) if $song;
    return $audio_info;
}

sub _store_audio_info {
    my ($song, $audio_info) = @_;
    return unless $song && ref $audio_info eq 'HASH';

    $song->pluginData('twitchAudioInfo', $audio_info);

    # Keep LMS' track properties in sync as well. Material Skin can obtain
    # technical metadata from either getMetadataFor() or the active track.
    for my $method (qw(track currentTrack)) {
        next unless $song->can($method);
        my $track = $song->$method or next;
        $track->samplerate($audio_info->{sample_rate})
            if $audio_info->{sample_rate} && $track->can('samplerate');
    }

    my $client = $song->master;
    my $display_type = _audio_type($client, $audio_info);
    my $song_meta = $song->pluginData('wmaMeta');
    if (ref $song_meta eq 'HASH') {
        $song->pluginData('wmaMeta', {
            %$song_meta,
            type         => $display_type,
            originalType => $display_type,
        });
    }

    my ($type, $id) = _twitch_media_id($song);
    return unless $type && $id;
    $id = lc $id if $type eq 'live';
    my $cache = Slim::Utils::Cache->new;
    $cache->set(
        "twitch:audio-info:$type:$id",
        $audio_info,
        Plugins::Twitch::Config::cache_ttl(),
    );
    my $cached_meta = $cache->get("twitch:$type:$id");
    if (ref $cached_meta eq 'HASH') {
        $cache->set(
            "twitch:$type:$id",
            {
                %$cached_meta,
                type         => $display_type,
                originalType => $display_type,
            },
            Plugins::Twitch::Config::cache_ttl(),
        );
    }
    return;
}

sub _song_for_url {
    my ($client, $url) = @_;
    return unless $client;

    if ($client->can('currentSongForUrl')) {
        my $song = $client->currentSongForUrl($url);
        return $song if $song;
    }

    # Never bind metadata for an explicitly identifiable URL to whichever
    # song happens to still be playing during a track transition.
    return if _twitch_media_id(undef, $url);
    return $client->playingSong;
}

sub canSeek {
    my ($class, $client, $song) = @_;
    return _is_vod_song($song) && $song->duration ? 1 : 0;
}

sub _resume_cache_key {
    my ($song) = @_;
    return unless $song;

    my ($type, $id) = _twitch_media_id($song);
    return unless $type && $type eq 'vod' && $id;

    my $client = $song->master;
    my $client_id = $client && $client->can('id') ? $client->id : undef;
    return unless defined $client_id && length $client_id;
    return "twitch:resume:$client_id:vod:$id";
}

sub _set_resume_position {
    my ($song, $position) = @_;
    return unless $song && defined $position;

    $song->pluginData('twitchResumePosition', $position);
    return;
}

sub _persist_resume_position {
    my ($song, $position) = @_;
    return unless $song && defined $position;

    _set_resume_position($song, $position);
    my $key = _resume_cache_key($song) or return;
    Slim::Utils::Cache->new->set(
        $key,
        $position,
        Plugins::Twitch::Config::cache_ttl(),
    );
    return;
}

sub _resume_position {
    my ($song) = @_;
    return unless $song;

    my $position = $song->pluginData('twitchResumePosition');
    return $position if defined $position;

    my $key = _resume_cache_key($song) or return;
    return Slim::Utils::Cache->new->get($key);
}

sub getSeekData {
    my ($class, $client, $song, $newtime) = @_;
    _persist_resume_position($song, $newtime) if _is_vod_song($song);
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
    my $client = $song->master;
    $client->currentPlaylistUpdateTime(time())
        if $client->can('currentPlaylistUpdateTime');
    Slim::Control::Request::notifyFromArray(
        $client,
        ['newmetadata'],
    );
}

sub _audio_type {
    # Material Skin obtains the service from the track URL/protocol, the
    # codec from type and the sample rate from samplerate. Keep these fields
    # separate; commas and parenthesized values are not parsed as extra
    # technical fields. The exact profile remains in twitchAudioInfo.
    return 'aac';
}

sub getMetadataFor {
    my ($class, $client, $url, undef, $song) = @_;
    $song ||= _song_for_url($client, $url);

    my $meta = _restore_cached_metadata($song, $url);
    my ($url_type, $media_id) = _twitch_media_id($song, $url);
    my $is_vod = $url_type ? $url_type eq 'vod' : _is_vod_song($song);
    my $audio_info = _restore_audio_info($song, $url);
    my $type = _audio_type($client, $audio_info);
    my $sample_rate = ref $audio_info eq 'HASH'
        ? $audio_info->{sample_rate}
        : undef;
    # Material Skin derives the displayed service from the metadata URL.
    # Keep the public twitch: identity here even while playback uses an
    # internal twitchhls: or HTTPS media-playlist URL.
    my $metadata_url = $url_type && defined $media_id
        ? "twitch:$url_type:$media_id"
        : $url;

    return {
        title        => $meta->{title},
        artist       => $meta->{artist},
        cover        => $meta->{cover},
        icon         => $meta->{cover},
        duration     => $is_vod && $song ? ($song->duration || undef) : undef,
        samplerate   => $sample_rate,
        type         => $type,
        originalType => $type,
        url          => $metadata_url,
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
    my $is_vod = _is_vod_song($song);
    if ($is_vod && $song) {
        my $resume_time = _resume_position($song);
        $seek_time = $resume_time
            if defined $resume_time
                && (!defined $seek_time || $seek_time <= 0);
    }
    $seek_time = undef unless $is_vod;

    _set_progress_offset($song, $seek_time)
        if defined $seek_time && $seek_time > 0;

    my $self = $class->SUPER::new;
    ${*$self}{song} = $song;
    ${*$self}{playlist_url} = $url;
    ${*$self}{is_vod} = $is_vod;
    ${*$self}{resume_time} = $seek_time;
    $self->_start_session;

    $log->info('Twitch HLS reader opened');
    $log->debug("Twitch HLS playlist URL: $url");
    return $self;
}

sub _start_session {
    my ($self) = @_;
    my $song = ${*$self}{song};
    my $is_vod = ${*$self}{is_vod};
    my $seek_time = $is_vod ? ${*$self}{resume_time} : undef;

    ${*$self}{session} = Plugins::Twitch::HLS::Session->new({
        playlist_url => ${*$self}{playlist_url},
        is_vod       => $is_vod,
        seek_time    => $seek_time,
        log          => $log,
        on_duration  => sub {
            my ($duration) = @_;
            return unless $is_vod && $song && $duration;
            return if $song->duration
                && abs($song->duration - $duration) < 0.01;
            $song->duration($duration);
            _notify_metadata($song);
        },
        on_audio_info => sub {
            my ($audio_info) = @_;
            return unless $song && ref $audio_info eq 'HASH';
            _store_audio_info($song, $audio_info);
            _notify_metadata($song);
        },
        on_seek => sub {
            my ($offset) = @_;
            _set_progress_offset($song, $offset);
        },
    });
    ${*$self}{closed} = 0;
    return;
}

sub close {
    my ($self) = @_;
    if (${*$self}{is_vod} && ${*$self}{session}) {
        my $position = ${*$self}{session}->position;
        if ($position > 0) {
            ${*$self}{resume_time} = $position;
            _persist_resume_position(${*$self}{song}, $position);
            $log->debug(sprintf(
                'Twitch HLS VOD resume position stored: %.1f s',
                $position,
            ));
        }
    }
    ${*$self}{closed} = 1;
    ${*$self}{session}->close if ${*$self}{session};
    delete ${*$self}{session};
    return;
}

sub sysread {
    my ($self, undef, $max_bytes) = @_;
    if (${*$self}{closed} || !${*$self}{session}) {
        $log->info('Twitch HLS reader resumed after standby');
        $self->_start_session;
    }

    my $bytes = ${*$self}{session}->read($max_bytes);
    if (defined $bytes) {
        if (${*$self}{is_vod} && length($bytes)) {
            my $position = ${*$self}{session}->position;
            ${*$self}{resume_time} = $position;
            my $song = ${*$self}{song};
            _set_resume_position($song, $position);

            my $last_write = ${*$self}{last_resume_cache_write} || 0;
            if (time() - $last_write >= RESUME_CACHE_INTERVAL) {
                _persist_resume_position($song, $position);
                ${*$self}{last_resume_cache_write} = time();
            }
        }
        $_[1] = $bytes;
        return length($bytes);
    }

    $! = IO_SELECT_FIXED ? EWOULDBLOCK : EINTR;
    return undef;
}

1;
