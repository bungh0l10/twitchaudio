package Plugins::Twitch::HLSStream;

# Native HLS reader for Twitch MPEG-TS and fragmented MP4 audio renditions.
# This is an IO::Handle because LMS consumes protocol handlers via sysread().

use strict;
use warnings;
use bytes;

use base qw(IO::Handle);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Player::ProtocolHandlers;
use Slim::Control::Request ();
use Slim::Utils::Errno;
use Slim::Utils::Log qw(logger);
use Slim::Utils::Versions ();
use Time::HiRes qw(time);
use URI;

use Plugins::Twitch::MPEGTSAAC ();
use Plugins::Twitch::MP4AAC ();

my $log = logger('plugin.twitch');

Slim::Player::ProtocolHandlers->registerHandler('twitchhls', __PACKAGE__);

use constant {
    HTTP_TIMEOUT => 20,
    PREFETCH     => 3,
};

# LMS releases before 7.9.1 retry an IO handler only for EINTR.  Newer LMS
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

# Called by LMS before it starts its generic remote scanner.  The generic
# scanner treats an HLS media playlist as an M3U playlist and follows its
# relative TS entries, which is precisely what we must avoid.
sub scanStream {
    my ($class, $url, $track, $args) = @_;

    $track->content_type('aac');
    $track->update;

    # The originating twitch: song initially belongs to ProtocolHandler
    # (which inherits HTTPS).  Without replacing it here LMS attempts to
    # open twitchhls:// with HTTPS once, waits for its socket timeout, and
    # only then retries with this handler.
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

    my $self = $class->SUPER::new;
    ${*$self}{playlist_url} = $url;
    ${*$self}{song}         = $song;
    ${*$self}{segments}     = [];
    ${*$self}{seen}         = {};
    ${*$self}{epoch}        = 0;
    ${*$self}{last_sequence}= undef;
    ${*$self}{ts_extractor} = Plugins::Twitch::MPEGTSAAC->new({
        log => $log,
    });
    ${*$self}{mp4_extractor}= Plugins::Twitch::MP4AAC->new({
        log => $log,
    });
    ${*$self}{started}      = 0;
    ${*$self}{next_playlist}= 0;
    ${*$self}{seek_time}    = ($song && $song->seekdata)
        ? $song->seekdata->{timeOffset}
        : undef;

    # HLS seeking starts a fresh stream at the selected segment. Tell LMS
    # which VOD timestamp that new stream represents, otherwise its elapsed
    # time (and therefore the progress marker) starts at zero again.
    _set_progress_offset($song, ${*$self}{seek_time})
        if defined ${*$self}{seek_time} && ${*$self}{seek_time} > 0;

    $log->info("Twitch HLS reader opened: $url");
    $self->_fetch_playlist;
    return $self;
}

sub close {
    my ($self) = @_;
    ${*$self}{closed} = 1;
    delete ${*$self}{playlist_request};
    delete ${*$self}{init_request};
    delete ${*$self}{segment_request};
    return;
}

sub _request {
    my ($self, $url, $success, $failure) = @_;
    return if ${*$self}{closed};

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my ($response) = @_;
            $success->($response->content) unless ${*$self}{closed};
        },
        sub {
            my ($response, $error, $http_response) = @_;
            my $status = $http_response ? $http_response->status_line : $error;
            $failure->($status || 'unknown error') unless ${*$self}{closed};
        },
        { timeout => HTTP_TIMEOUT },
    );

    $http->get($url, 'User-Agent' => 'LMS Twitch Audio');
    return $http;
}

sub _fetch_playlist {
    my ($self) = @_;
    return if ${*$self}{closed} || ${*$self}{playlist_request};

    my $url = ${*$self}{playlist_url} or return;
    ${*$self}{playlist_request} = $self->_request($url, sub {
        my ($body) = @_;
        delete ${*$self}{playlist_request};
        $self->_parse_playlist($body);
        $self->_fetch_segments;
    }, sub {
        my ($error) = @_;
        delete ${*$self}{playlist_request};
        ${*$self}{next_playlist} = time() + 3;
        $log->warn("Twitch HLS playlist request failed: $error");
    });
}

sub _parse_playlist {
    my ($self, $body) = @_;
    return unless defined $body && $body =~ /#EXTM3U/;

    my ($sequence) = $body =~ /#EXT-X-MEDIA-SEQUENCE:(\d+)/;
    $sequence //= 0;
    if (defined ${*$self}{last_sequence} && $sequence < ${*$self}{last_sequence}) {
        ${*$self}{epoch}++;
        ${*$self}{seen} = {};
        ${*$self}{ts_extractor} = Plugins::Twitch::MPEGTSAAC->new({
            log => $log,
        });
        $log->info('Twitch HLS playlist sequence restarted');
    }
    ${*$self}{last_sequence} = $sequence;

    my $endlist = $body =~ /#EXT-X-ENDLIST/;
    my @new;
    my ($duration, $last_duration, $total_duration, $discontinuity, $index)
        = (0, 6, 0, 0, 0);
    my $map_url;
    for my $line (split /\r?\n/, $body) {
        if ($line =~ /^#EXT-X-DISCONTINUITY/) { $discontinuity = 1; next; }
        if ($line =~ /^#EXT-X-MAP:.*\bURI="([^"]+)"/) {
            $map_url = URI->new_abs(
                $1, ${*$self}{playlist_url},
            )->as_string;
            next;
        }
        if ($line =~ /^#EXTINF:([\d.]+)/) { $duration = $1; next; }
        next if $line =~ /^#/ || $line !~ /\S/;

        my $id = join(':', ${*$self}{epoch}, $sequence + $index++);
        next if ${*$self}{seen}{$id};
        ${*$self}{seen}{$id} = 1;
        push @new, {
            id            => $id,
            url           => URI->new_abs($line, ${*$self}{playlist_url})->as_string,
            duration      => $duration,
            discontinuity => $discontinuity,
            map_url       => $map_url,
            container     => $map_url ? 'mp4' : undef,
        };
        $discontinuity = 0;
        $last_duration = $duration if $duration;
        $total_duration += $duration;
    }

    # Start a live stream close to its live edge, rather than replaying a
    # potentially long initial playlist window.
    if (!${*$self}{started} && !$endlist && @new > 3) {
        @new = splice @new, -3;
    }
    ${*$self}{started} = 1 if @new;

    if ($endlist) {
        my $song = ${*$self}{song};
        if ($song && $total_duration) {
            $song->duration($total_duration);
            Slim::Control::Request::notifyFromArray(
                $song->master,
                ['newmetadata'],
            );
        }

        # HLS has no byte offset. Seek to the segment containing the desired
        # time; the maximum inaccuracy is one HLS segment (usually 2 s).
        if (defined ${*$self}{seek_time} && ${*$self}{seek_time} > 0) {
            my ($elapsed, $first) = (0, 0);
            for my $segment (@new) {
                last if $elapsed + $segment->{duration} > ${*$self}{seek_time};
                $elapsed += $segment->{duration};
                $first++;
            }
            splice @new, 0, $first if $first;
            _set_progress_offset(${*$self}{song}, $elapsed);
            $log->info(sprintf 'Twitch HLS VOD seek: %.1f s -> segment at %.1f s',
                ${*$self}{seek_time}, $elapsed);
        }
    }

    push @{ ${*$self}{segments} }, @new;
    ${*$self}{endlist} = $endlist;
    ${*$self}{next_playlist} = time() + (($last_duration > 3) ? $last_duration - 2 : 1)
        unless $endlist;
    $log->info(sprintf 'Twitch HLS playlist: %d queued segment(s), %s',
        scalar(@new), $endlist ? 'VOD' : 'live');
}

sub _fetch_segments {
    my ($self) = @_;
    return if ${*$self}{closed};

    my $segments = ${*$self}{segments};
    my $buffered = scalar grep {
        $_->{fetching} || defined $_->{aac}
    } @$segments;
    return if $buffered >= PREFETCH;

    for my $segment (@$segments) {
        next if $segment->{fetching} || defined $segment->{aac};

        if ($segment->{map_url}
            && (!${*$self}{current_init_url}
                || ${*$self}{current_init_url} ne $segment->{map_url}))
        {
            $self->_fetch_init($segment->{map_url});
            return;
        }

        $segment->{fetching} = 1;
        ${*$self}{segment_request} = $self->_request($segment->{url}, sub {
            my ($media) = @_;
            delete ${*$self}{segment_request};
            delete $segment->{fetching};
            $segment->{aac} = $self->_extract_segment($segment, $media);
            if ($segment->{duration} && length($segment->{aac})) {
                my $bitrate = length($segment->{aac}) * 8 / $segment->{duration};
                # AAC is usually VBR. Round the short segment measurement to
                # a stable 8 kbit/s step before exposing it as stream metadata.
                $bitrate = int(($bitrate + 4_000) / 8_000) * 8_000;

                my $song = ${*$self}{song};
                if ($song && !$song->bitrate) {
                    $song->bitrate($bitrate);
                    Slim::Control::Request::notifyFromArray(
                        $song->master,
                        ['newmetadata'],
                    );
                }
            }
            $log->info(sprintf 'Twitch HLS %s segment: %d bytes, %d ADTS bytes',
                uc($segment->{container} || 'mpeg-ts'),
                length($media || ''), length($segment->{aac}));
            $self->_fetch_segments;
        }, sub {
            my ($error) = @_;
            delete ${*$self}{segment_request};
            delete $segment->{fetching};
            $log->warn("Twitch HLS segment request failed: $error");
        });
        last; # preserve TS/PES order; one segment request at a time
    }
}

sub _fetch_init {
    my ($self, $url) = @_;
    return if ${*$self}{closed} || ${*$self}{init_request};

    ${*$self}{init_request} = $self->_request($url, sub {
        my ($init) = @_;
        delete ${*$self}{init_request};
        if (${*$self}{mp4_extractor}->set_init($init)) {
            ${*$self}{current_init_url} = $url;
            $self->_fetch_segments;
        } else {
            $log->warn("Twitch HLS MP4 init segment is unsupported: $url");
        }
    }, sub {
        my ($error) = @_;
        delete ${*$self}{init_request};
        $log->warn("Twitch HLS MP4 init request failed: $error");
    });
}

sub _extract_segment {
    my ($self, $segment, $media) = @_;
    return '' unless defined $media;

    if ($segment->{container} && $segment->{container} eq 'mp4') {
        return ${*$self}{mp4_extractor}->extract($media);
    }

    # EXT-X-MAP is authoritative, but sniff fragmented MP4 as a fallback for
    # non-conforming playlists which omit it.
    if (length($media) >= 8
        && substr($media, 4, 4) =~ /^(?:ftyp|styp|moof)$/)
    {
        $segment->{container} = 'mp4';
        $log->warn('Twitch HLS MP4 segment has no EXT-X-MAP; cannot decode it');
        return '';
    }

    $segment->{container} = 'mpeg-ts';
    return ${*$self}{ts_extractor}->extract($media);
}

sub sysread {
    my ($self, undef, $max_bytes) = @_;
    return 0 if ${*$self}{closed};
    my $segments = ${*$self}{segments};
    if (@$segments && defined $segments->[0]{aac}) {
        my $segment = $segments->[0];
        my $offset = $segment->{offset} || 0;
        my $bytes = substr($segment->{aac}, $offset, $max_bytes);
        $segment->{offset} = $offset + length($bytes);
        shift @$segments if $segment->{offset} >= length($segment->{aac});
        $_[1] = $bytes;
        $self->_fetch_segments;
        return length($bytes);
    }
    shift @$segments if @$segments && defined($segments->[0]{aac}) && !length($segments->[0]{aac});
    $self->_fetch_segments;
    $self->_fetch_playlist
        if !${*$self}{endlist}
            && !${*$self}{playlist_request}
            && time() >= ${*$self}{next_playlist};
    return 0 if ${*$self}{endlist} && !@$segments && !${*$self}{segment_request};
    $! = IO_SELECT_FIXED ? EWOULDBLOCK : EINTR;
    return undef;
}

1;
