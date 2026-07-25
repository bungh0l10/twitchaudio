package Plugins::Twitch::HLS::Session;

use strict;
use warnings;
use bytes;

use Slim::Networking::SimpleAsyncHTTP;
use Time::HiRes qw(time);

use Plugins::Twitch::HLS::Playlist ();
use Plugins::Twitch::HLS::Extractor::MPEGTSAAC ();
use Plugins::Twitch::HLS::Extractor::MP4AAC ();

use constant {
    HTTP_TIMEOUT => 20,
    PREFETCH     => 3,
    RETRY_DELAY  => 3,
};

sub new {
    my ($class, $args) = @_;
    my $self = bless {
        playlist_url  => $args->{playlist_url},
        is_vod        => $args->{is_vod} ? 1 : 0,
        seek_time     => $args->{seek_time},
        log           => $args->{log},
        on_duration   => $args->{on_duration} || sub {},
        on_bitrate    => $args->{on_bitrate} || sub {},
        on_seek       => $args->{on_seek} || sub {},
        segments      => [],
        seen          => {},
        epoch         => 0,
        started       => 0,
        next_playlist => 0,
    }, $class;

    $self->_reset_extractors;
    $self->_fetch_playlist;
    return $self;
}

sub close {
    my ($self) = @_;
    $self->{closed} = 1;
    delete @$self{qw(playlist_request init_request segment_request)};
    return;
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

sub _request {
    my ($self, $url, $success, $failure) = @_;
    return if $self->{closed};

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

    if (defined $self->{last_sequence} && $sequence < $self->{last_sequence}) {
        $self->{epoch}++;
        $self->{seen} = {};
        $self->_reset_extractors;
        $self->{log}->debug('Twitch HLS playlist sequence restarted');
    }
    $self->{last_sequence} = $sequence;

    my @new;
    for my $segment (@{ $playlist->segments }) {
        my $id = join(':', $self->{epoch}, $segment->{sequence});
        next if $self->{seen}{$id};
        $self->{seen}{$id} = 1;
        push @new, { %$segment, id => $id };
    }

    if (!$self->{started} && !$self->{is_vod} && @new > 3) {
        @new = splice @new, -3;
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
            $self->{on_seek}->($target->{start_time});
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

sub _fetch_segments {
    my ($self) = @_;
    return if $self->{closed}
        || $self->{segment_request}
        || $self->{init_request};

    my $buffered = scalar grep { defined $_->{aac} }
        @{ $self->{segments} };
    return if $buffered >= PREFETCH;

    for my $segment (@{ $self->{segments} }) {
        next if defined $segment->{aac};
        return if $segment->{retry_at} && time() < $segment->{retry_at};

        if ($segment->{muted}) {
            $self->{log}->info(
                'Audio for this section has been muted by Twitch because it contains copyrighted content.'
            );
            $segment->{aac} = '';
            $self->_fetch_segments;
            return;
        }

        if ($segment->{init_url}
            && (!$self->{current_init_url}
                || $self->{current_init_url} ne $segment->{init_url}))
        {
            $self->_fetch_init($segment->{init_url});
            return;
        }

        $self->{segment_request} = $self->_request($segment->{url}, sub {
            my ($media) = @_;
            delete $self->{segment_request};
            delete $segment->{retry_at};
            $segment->{aac} = $self->_extract_segment($segment, $media);
            $self->_report_bitrate($segment);
            $self->{log}->debug(sprintf(
                'Twitch HLS %s segment: %d bytes, %d ADTS bytes',
                uc($segment->{container} || 'mpeg-ts'),
                length($media || ''), length($segment->{aac}),
            ));
            $self->_fetch_segments;
        }, sub {
            my ($error) = @_;
            delete $self->{segment_request};
            $segment->{retry_at} = time() + RETRY_DELAY;
            $self->{log}->error("Twitch HLS segment request failed: $error");
        });
        return;
    }
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

sub _report_bitrate {
    my ($self, $segment) = @_;
    return unless $segment->{duration} && length($segment->{aac});

    my $bitrate = length($segment->{aac}) * 8 / $segment->{duration};
    $bitrate = int(($bitrate + 4_000) / 8_000) * 8_000;
    $self->{on_bitrate}->($bitrate);
}

sub read {
    my ($self, $max_bytes) = @_;
    return '' if $self->{closed};

    while (@{ $self->{segments} }
        && defined $self->{segments}[0]{aac})
    {
        my $segment = $self->{segments}[0];
        if (!length($segment->{aac})) {
            shift @{ $self->{segments} };
            next;
        }

        my $offset = $segment->{offset} || 0;
        my $bytes = substr($segment->{aac}, $offset, $max_bytes);
        $segment->{offset} = $offset + length($bytes);
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
            && !$self->{segment_request}
            && !$self->{init_request};

    return undef;
}

1;
