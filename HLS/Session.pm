package Plugins::Twitch::HLS::Session;

use strict;
use warnings;
use bytes;

use Slim::Networking::SimpleAsyncHTTP;
use Time::HiRes qw(time);
use URI;

use Plugins::Twitch::HLS::Playlist ();
use Plugins::Twitch::HLS::Extractor::MPEGTSAAC ();
use Plugins::Twitch::HLS::Extractor::MP4AAC ();

use constant {
    HTTP_TIMEOUT        => 20,
    MAX_CONCURRENT_REQUESTS => 3,
    DEFAULT_LIVE_BUFFER_SECONDS => 12,
    DEFAULT_LIVE_INITIAL_SEGMENTS => 5,
    VOD_BUFFER_SECONDS  => 30,
    RETRY_DELAY         => 3,
    SEEN_HISTORY_MARGIN => 10,
};

sub _adts_frame_length {
    my ($aac, $offset) = @_;
    return unless defined $aac && defined $offset
        && $offset >= 0 && $offset + 7 <= length($aac);

    return unless ord(substr($aac, $offset, 1)) == 0xff
        && (ord(substr($aac, $offset + 1, 1)) & 0xf6) == 0xf0;

    my $length = ((ord(substr($aac, $offset + 3, 1)) & 3) << 11)
        | (ord(substr($aac, $offset + 4, 1)) << 3)
        | ((ord(substr($aac, $offset + 5, 1)) & 0xe0) >> 5);

    return unless $length >= 7 && $offset + $length <= length($aac);
    return $length;
}

sub _adts_offset_for_fraction {
    my ($aac, $fraction) = @_;
    return 0 unless defined $aac && length($aac);

    $fraction = 0 unless defined $fraction && $fraction > 0;
    $fraction = 1 if $fraction > 1;

    my @offsets;
    my $offset = 0;
    while ($offset + 7 <= length($aac)) {
        my $frame_length = _adts_frame_length($aac, $offset);
        unless ($frame_length) {
            my $next = index($aac, "\xff", $offset + 1);
            return length($aac) if $next < 0;
            $offset = $next;
            next;
        }

        push @offsets, $offset;
        $offset += $frame_length;
    }

    return length($aac) unless @offsets;

    my $target_frame = $fraction * scalar(@offsets);
    my $index = int($target_frame);
    $index++ if $target_frame > $index;

    return $index < @offsets ? $offsets[$index] : length($aac);
}

sub _positive_number {
    my ($value, $default) = @_;
    return $default unless defined $value
        && $value =~ /^\d+(?:\.\d+)?$/
        && $value > 0;
    return $value + 0;
}

sub _positive_integer {
    my ($value, $default, $maximum) = @_;
    return $default unless defined $value
        && $value =~ /^\d+$/
        && $value > 0
        && (!defined $maximum || $value <= $maximum);
    return $value + 0;
}

sub new {
    my ($class, $args) = @_;
    my $self = bless {
        playlist_url  => $args->{playlist_url},
        is_vod        => $args->{is_vod} ? 1 : 0,
        seek_time     => $args->{seek_time},
        live_buffer_seconds => _positive_number(
            $args->{live_buffer_seconds}, DEFAULT_LIVE_BUFFER_SECONDS,
        ),
        live_initial_segments => _positive_integer(
            $args->{live_initial_segments}, DEFAULT_LIVE_INITIAL_SEGMENTS, 10,
        ),
        log           => $args->{log},
        on_duration   => $args->{on_duration} || sub {},
        on_audio_info => $args->{on_audio_info} || sub {},
        on_data       => $args->{on_data} || sub {},
        on_seek       => $args->{on_seek} || sub {},
        segments      => [],
        # Live and reloadable EVENT playlists allocate this lazily for
        # deduplication. A complete VOD is consumed from one immutable
        # playlist and does not need a second hash containing every segment.
        seen          => $args->{is_vod} ? undef : {},
        epoch         => 0,
        started       => 0,
        next_playlist => 0,
        position      => $args->{seek_time} || 0,
        prebuffer_ready => $args->{is_vod} ? 1 : 0,
    }, $class;

    $self->_reset_extractors;
    $self->_fetch_playlist;
    return $self;
}

sub close {
    my ($self) = @_;
    $self->{closed} = 1;
    delete @$self{qw(playlist_request init_request)};
    delete $_->{request} for @{ $self->{segments} };
    return;
}

sub position {
    my ($self) = @_;
    return $self->{position} || 0;
}

sub _reset_extractors {
    my ($self) = @_;
    $self->{ts_extractor}
        = Plugins::Twitch::HLS::Extractor::MPEGTSAAC->new({
            log => $self->{log},
        });
    $self->{mp4_extractor}
        = Plugins::Twitch::HLS::Extractor::MP4AAC->new({
            log => $self->{log},
        });
    delete $self->{current_init_url};
}

sub _prune_live_seen {
    my ($self, $window_sequence) = @_;
    return if $self->{is_vod} || !defined $window_sequence;

    my $keep_from = $window_sequence > SEEN_HISTORY_MARGIN
        ? $window_sequence - SEEN_HISTORY_MARGIN
        : 0;
    my $removed = 0;

    for my $id (keys %{ $self->{seen} }) {
        my ($epoch, $sequence) = $id =~ /^(\d+):(\d+)$/;
        next if defined $epoch
            && $epoch == $self->{epoch}
            && $sequence >= $keep_from;
        delete $self->{seen}{$id};
        $removed++;
    }

    $self->{log}->debug(sprintf(
        'Twitch HLS pruned %d old live segment ID(s)', $removed,
    )) if $removed;
    return;
}

sub _apply_segment_discontinuity {
    my ($self, $segment) = @_;
    return unless $segment->{discontinuity}
        && !$segment->{discontinuity_applied};

    $self->_reset_extractors;
    $segment->{discontinuity_applied} = 1;
    $self->{log}->debug(
        'Twitch HLS discontinuity: reset container extraction state'
    );
    return 1;
}

sub _request {
    my ($self, $url, $success, $failure) = @_;
    return if $self->{closed};

    my $uri = URI->new($url || '');
    unless (lc($uri->scheme || '') eq 'https'
        && defined $uri->host && length($uri->host))
    {
        $failure->('refusing non-HTTPS or invalid HLS URL');
        return;
    }

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my ($response) = @_;
            $success->($response->content) unless $self->{closed};
        },
        sub {
            my ($response, $error, $http_response) = @_;
            my $status = $http_response ? $http_response->status_line : $error;
            $failure->($status || 'unknown error') unless $self->{closed};
        },
        { timeout => HTTP_TIMEOUT },
    );

    $http->get($url, 'User-Agent' => 'LMS Twitch Audio');
    return $http;
}

sub _fetch_playlist {
    my ($self) = @_;
    return if $self->{closed} || $self->{playlist_request};

    my $url = $self->{playlist_url} or return;
    $self->{playlist_request} = $self->_request($url, sub {
        my ($body) = @_;
        delete $self->{playlist_request};
        my $playlist = Plugins::Twitch::HLS::Playlist->parse($body, $url);
        unless ($playlist) {
            $self->{log}->error('Twitch HLS playlist is invalid');
            $self->{next_playlist} = time() + RETRY_DELAY;
            return;
        }
        $self->_apply_playlist($playlist);
        $self->_fetch_segments;
    }, sub {
        my ($error) = @_;
        delete $self->{playlist_request};
        $self->{next_playlist} = time() + RETRY_DELAY;
        $self->{log}->error("Twitch HLS playlist request failed: $error");
    });
}

sub _apply_playlist {
    my ($self, $playlist) = @_;
    my $sequence = $playlist->media_sequence;
    my $complete_vod = $self->{is_vod}
        && !$self->{started}
        && $playlist->is_complete;

    if (defined $self->{last_sequence} && $sequence < $self->{last_sequence}) {
        $self->{epoch}++;
        $self->{seen} = {};
        $self->_reset_extractors;
        $self->{log}->debug('Twitch HLS playlist sequence restarted');
    }
    $self->{last_sequence} = $sequence;
    $self->_prune_live_seen($sequence);

    my @new;
    for my $segment (@{ $playlist->segments }) {
        if ($complete_vod) {
            push @new, { %$segment };
            next;
        }

        $self->{seen} ||= {};
        my $id = join(':', $self->{epoch}, $segment->{sequence});
        next if $self->{seen}{$id};
        $self->{seen}{$id} = 1;
        push @new, { %$segment, id => $id };
    }

    my $initial_segments = $self->{live_initial_segments};
    if (!$self->{started} && !$self->{is_vod}
        && @new > $initial_segments)
    {
        @new = splice @new, -$initial_segments;
    }

    if ($self->{is_vod}
        && !$self->{started}
        && defined $self->{seek_time}
        && $self->{seek_time} > 0
        && $playlist->is_seekable)
    {
        my $target = $playlist->segment_at($self->{seek_time});
        if ($target) {
            @new = grep { $_->{sequence} >= $target->{sequence} } @new;
            if (@new && $target->{duration}) {
                $new[0]{initial_fraction} =
                    ($self->{seek_time} - $target->{start_time})
                    / $target->{duration};
                $new[0]{initial_fraction} = 0
                    if $new[0]{initial_fraction} < 0;
                $new[0]{initial_fraction} = 1
                    if $new[0]{initial_fraction} > 1;
            }
            $self->{on_seek}->($self->{seek_time});
            $self->{position} = $self->{seek_time};
            $self->{log}->info(sprintf(
                'Twitch HLS VOD seek: %.1f s -> segment at %.1f s',
                $self->{seek_time}, $target->{start_time},
            ));
        }
    }

    $self->{started} = 1 if @new;
    push @{ $self->{segments} }, @new;

    if ($self->{is_vod}
        && defined $playlist->total_duration
        && $playlist->total_duration > 0)
    {
        $self->{on_duration}->($playlist->total_duration);
    }

    $self->{complete} = $self->{is_vod}
        ? $playlist->is_complete
        : $playlist->endlist;
    $self->{next_playlist} = time() + $playlist->reload_after
        unless $self->{complete};

    $self->{log}->debug(sprintf(
        'Twitch HLS playlist: %d queued segment(s), %s',
        scalar(@new), $self->{complete} ? 'complete' : 'reloadable',
    ));
}

sub _fetch_init {
    my ($self, $url) = @_;
    return if $self->{closed} || $self->{init_request};
    return if $self->{init_retry_url}
        && $self->{init_retry_url} eq $url
        && time() < ($self->{init_retry_at} || 0);

    $self->{init_request} = $self->_request($url, sub {
        my ($init) = @_;
        delete $self->{init_request};
        if ($self->{mp4_extractor}->set_init($init)) {
            delete @$self{qw(init_retry_url init_retry_at)};
            $self->{current_init_url} = $url;
            $self->_fetch_segments;
        } else {
            $self->{init_retry_url} = $url;
            $self->{init_retry_at} = time() + RETRY_DELAY;
            $self->{log}->error(
                "Twitch HLS MP4 init segment is unsupported: $url"
            );
        }
    }, sub {
        my ($error) = @_;
        delete $self->{init_request};
        $self->{init_retry_url} = $url;
        $self->{init_retry_at} = time() + RETRY_DELAY;
        $self->{log}->error("Twitch HLS MP4 init request failed: $error");
    });
}

sub _process_downloaded_segments {
    my ($self) = @_;
    return if $self->{closed};

    my $target = $self->{is_vod}
        ? VOD_BUFFER_SECONDS
        : $self->{live_buffer_seconds};
    return if $self->_buffered_seconds >= $target;

    for my $segment (@{ $self->{segments} }) {
        next if defined $segment->{aac};

        if ($segment->{muted}) {
            $self->{log}->info(
                'Audio for this section has been muted by Twitch because it contains copyrighted content.'
            );
            $segment->{aac} = '';
            next;
        }

        # Downloads may finish out of order, but extraction is stateful and
        # must cross discontinuities and initialization changes in order.
        return unless defined $segment->{media};
        $self->_apply_segment_discontinuity($segment);

        if ($segment->{init_url}
            && (!$self->{current_init_url}
                || $self->{current_init_url} ne $segment->{init_url}))
        {
            $self->_fetch_init($segment->{init_url});
            return;
        }

        my $media = delete $segment->{media};
        $segment->{aac} = $self->_extract_segment($segment, $media);
        if (defined $segment->{initial_fraction}
            && length($segment->{aac}))
        {
            my $target_offset = int(
                length($segment->{aac}) * $segment->{initial_fraction}
            );
            $segment->{offset} = _adts_offset_for_fraction(
                $segment->{aac}, $segment->{initial_fraction},
            );
            $self->{log}->debug(sprintf(
                'Twitch HLS VOD ADTS seek alignment: %d -> %d bytes',
                $target_offset, $segment->{offset},
            ));
            delete $segment->{initial_fraction};
        }
        $self->_report_audio_info($segment->{aac});
        $self->{on_data}->() if length($segment->{aac});

        my $continuity = '';
        if (($segment->{container} || '') eq 'mpeg-ts') {
            my $info = $self->{ts_extractor}->continuity_info;
            if ($info) {
                $continuity = sprintf(
                    ', AAC PID 0x%04x, CC %d->%d (%d packets, %d jumps)',
                    @$info{qw(pid first last packets jumps)},
                );
            }
        }
        $self->{log}->debug(sprintf(
            'Twitch HLS %s segment %s: %d bytes, %d ADTS bytes%s',
            uc($segment->{container} || 'mpeg-ts'),
            defined $segment->{sequence} ? $segment->{sequence} : '?',
            length($media), length($segment->{aac}), $continuity,
        ));
        last if $self->_buffered_seconds >= $target;
    }

    return;
}

sub _segment_buffer_seconds {
    my ($segment) = @_;
    return 0 if $segment->{muted};
    my $duration = $segment->{duration} || 0;
    return 0 unless $duration > 0;

    if (defined $segment->{aac}) {
        my $length = length($segment->{aac});
        return 0 unless $length;
        my $offset = $segment->{offset} || 0;
        return $duration * (1 - $offset / $length)
            if $offset > 0 && $offset < $length;
        return 0 if $offset >= $length;
    }

    return $duration;
}

sub _buffered_seconds {
    my ($self) = @_;
    my $seconds = 0;

    for my $segment (@{ $self->{segments} }) {
        last unless defined $segment->{aac};
        $seconds += _segment_buffer_seconds($segment);
    }

    return $seconds;
}

sub _fetch_segments {
    my ($self) = @_;
    return if $self->{closed};

    $self->_process_downloaded_segments;

    my $target = $self->{is_vod}
        ? VOD_BUFFER_SECONDS
        : $self->{live_buffer_seconds};
    my $window_seconds = 0;
    my $active_requests = scalar grep { $_->{request} }
        @{ $self->{segments} };

    for my $segment (@{ $self->{segments} }) {
        last if $window_seconds >= $target;

        my $duration = _segment_buffer_seconds($segment);
        if (defined $segment->{aac}
            || defined $segment->{media}
            || $segment->{request}
            || $segment->{muted})
        {
            $window_seconds += $duration;
            next;
        }

        if ($segment->{retry_at} && time() < $segment->{retry_at}) {
            $window_seconds += $duration;
            next;
        }

        $window_seconds += $duration;
        next if $active_requests >= MAX_CONCURRENT_REQUESTS;

        $segment->{request} = $self->_request($segment->{url}, sub {
            my ($media) = @_;
            delete $segment->{request};
            delete $segment->{retry_at};
            $segment->{media} = $media;
            $self->_fetch_segments;
        }, sub {
            my ($error) = @_;
            delete $segment->{request};
            $segment->{retry_at} = time() + RETRY_DELAY;
            $self->{log}->error("Twitch HLS segment request failed: $error");
        });
        $active_requests++ if $segment->{request};
    }

    return;
}

sub _has_segment_requests {
    my ($self) = @_;
    return scalar grep { $_->{request} } @{ $self->{segments} };
}

sub _extract_segment {
    my ($self, $segment, $media) = @_;
    return '' unless defined $media;

    if ($segment->{container} && $segment->{container} eq 'mp4') {
        return $self->{mp4_extractor}->extract($media);
    }

    if (length($media) >= 8
        && substr($media, 4, 4) =~ /^(?:ftyp|styp|moof)$/)
    {
        $segment->{container} = 'mp4';
        $self->{log}->error(
            'Twitch HLS MP4 segment has no EXT-X-MAP; cannot decode it'
        );
        return '';
    }

    $segment->{container} = 'mpeg-ts';
    return $self->{ts_extractor}->extract($media);
}

sub _report_audio_info {
    my ($self, $aac) = @_;
    return if $self->{audio_info_reported}
        || !defined $aac || length($aac) < 7;

    my $offset = 0;
    while ($offset + 7 <= length($aac)) {
        if (ord(substr($aac, $offset, 1)) == 0xff
            && (ord(substr($aac, $offset + 1, 1)) & 0xf6) == 0xf0)
        {
            my @sample_rates = (
                96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000,
                22_050, 16_000, 12_000, 11_025, 8_000, 7_350,
            );
            my @profiles = ('AAC Main', 'AAC-LC', 'AAC-SSR', 'AAC-LTP');
            my $byte2 = ord(substr($aac, $offset + 2, 1));
            my $byte3 = ord(substr($aac, $offset + 3, 1));
            my $profile_index = ($byte2 >> 6) & 3;
            my $rate_index = ($byte2 >> 2) & 0x0f;
            my $channels = (($byte2 & 1) << 2) | (($byte3 >> 6) & 3);
            return if $rate_index >= @sample_rates;

            $self->{audio_info_reported} = 1;
            $self->{on_audio_info}->({
                profile     => $profiles[$profile_index],
                sample_rate => $sample_rates[$rate_index],
                channels    => $channels,
            });
            return;
        }
        $offset++;
    }
}

sub read {
    my ($self, $max_bytes) = @_;
    return '' if $self->{closed};

    if (!$self->{prebuffer_ready}) {
        $self->_fetch_segments;
        $self->_fetch_playlist
            if !$self->{complete}
                && !$self->{playlist_request}
                && time() >= $self->{next_playlist};

        my $buffered = $self->_buffered_seconds;
        return undef
            if $buffered < $self->{live_buffer_seconds}
                && !$self->{complete};

        $self->{prebuffer_ready} = 1;
        $self->{log}->info(sprintf(
            'Twitch HLS live prebuffer ready: %.1f / %.1f seconds',
            $buffered,
            $self->{live_buffer_seconds},
        ));
    }

    while (@{ $self->{segments} }
        && defined $self->{segments}[0]{aac})
    {
        my $segment = $self->{segments}[0];
        if (!length($segment->{aac})) {
            $self->{position} = ($segment->{start_time} || 0)
                + ($segment->{duration} || 0);
            shift @{ $self->{segments} };
            next;
        }

        my $offset = $segment->{offset} || 0;
        my $bytes = substr($segment->{aac}, $offset, $max_bytes);
        $segment->{offset} = $offset + length($bytes);
        if (length($segment->{aac})) {
            $self->{position} = ($segment->{start_time} || 0)
                + ($segment->{duration} || 0)
                    * $segment->{offset} / length($segment->{aac});
        }
        shift @{ $self->{segments} }
            if $segment->{offset} >= length($segment->{aac});
        $self->_fetch_segments;
        return $bytes;
    }

    $self->_fetch_segments;
    $self->_fetch_playlist
        if !$self->{complete}
            && !$self->{playlist_request}
            && time() >= $self->{next_playlist};

    return ''
        if $self->{complete}
            && !@{ $self->{segments} }
            && !$self->_has_segment_requests
            && !$self->{init_request};

    return undef;
}

1;
