package Plugins::Twitch::MP4AAC;

use strict;
use warnings;
use bytes;

sub new {
    my ($class, $args) = @_;
    return bless {
        log           => $args->{log},
        default_sizes => {},
    }, $class;
}

sub _u32 {
    return unpack('N', substr($_[0], $_[1], 4));
}

sub _u64 {
    my ($high, $low) = unpack('NN', substr($_[0], $_[1], 8));
    return $high * 4_294_967_296 + $low;
}

sub _boxes {
    my ($data, $start, $end) = @_;
    $start //= 0;
    $end //= length($data);
    my @boxes;

    my $pos = $start;
    while ($pos + 8 <= $end) {
        my $size = _u32($data, $pos);
        my $type = substr($data, $pos + 4, 4);
        my $header = 8;
        if ($size == 1) {
            last if $pos + 16 > $end;
            $size = _u64($data, $pos + 8);
            $header = 16;
        } elsif ($size == 0) {
            $size = $end - $pos;
        }
        last if $size < $header || $pos + $size > $end;

        push @boxes, {
            type          => $type,
            start         => $pos,
            size          => $size,
            payload_start => $pos + $header,
            end           => $pos + $size,
        };
        $pos += $size;
    }

    return @boxes;
}

sub _children {
    my ($data, $box) = @_;
    return _boxes($data, $box->{payload_start}, $box->{end});
}

sub _child {
    my ($data, $box, $type) = @_;
    for my $child (_children($data, $box)) {
        return $child if $child->{type} eq $type;
    }
    return;
}

sub _descriptor_length {
    my ($data, $pos, $end) = @_;
    my $length = 0;
    for (1 .. 4) {
        return unless $pos < $end;
        my $byte = ord(substr($data, $pos++, 1));
        $length = ($length << 7) | ($byte & 0x7f);
        return ($length, $pos) unless $byte & 0x80;
    }
    return;
}

sub _audio_specific_config {
    my ($data, $esds) = @_;
    my $pos = $esds->{payload_start} + 4; # FullBox version and flags
    my $end = $esds->{end};

    # DecoderSpecificInfo (tag 0x05) is nested below ES_Descriptor and
    # DecoderConfigDescriptor, whose payloads start with fixed fields rather
    # than another descriptor. Scan the small esds payload for a valid tag.
    while ($pos < $end - 2) {
        if (ord(substr($data, $pos, 1)) == 0x05) {
            my ($length, $payload) = _descriptor_length(
                $data, $pos + 1, $end,
            );
            if (defined $length && $length >= 2 && $payload + $length <= $end) {
                return substr($data, $payload, $length);
            }
        }
        $pos++;
    }
    return;
}

sub _find_esds {
    my ($data, $box) = @_;
    my $pos = $box->{payload_start};
    while (($pos = index($data, 'esds', $pos)) >= 0 && $pos < $box->{end}) {
        my $start = $pos - 4;
        if ($start >= $box->{payload_start}) {
            my $size = _u32($data, $start);
            if ($size >= 12 && $start + $size <= $box->{end}) {
                return {
                    type          => 'esds',
                    start         => $start,
                    size          => $size,
                    payload_start => $start + 8,
                    end           => $start + $size,
                };
            }
        }
        $pos += 4;
    }
    return;
}

sub _track_id {
    my ($data, $trak) = @_;
    my $tkhd = _child($data, $trak, 'tkhd') or return;
    my $version = ord(substr($data, $tkhd->{payload_start}, 1));
    my $offset = $tkhd->{payload_start} + ($version == 1 ? 20 : 12);
    return if $offset + 4 > $tkhd->{end};
    return _u32($data, $offset);
}

sub _is_audio_track {
    my ($data, $trak) = @_;
    my $mdia = _child($data, $trak, 'mdia') or return;
    my $hdlr = _child($data, $mdia, 'hdlr') or return;
    return substr($data, $hdlr->{payload_start} + 8, 4) eq 'soun';
}

sub _parse_trex {
    my ($self, $data, $moov) = @_;
    my $mvex = _child($data, $moov, 'mvex') or return;
    for my $trex (_children($data, $mvex)) {
        next unless $trex->{type} eq 'trex';
        my $pos = $trex->{payload_start} + 4;
        next if $pos + 20 > $trex->{end};
        my $track_id = _u32($data, $pos);
        $self->{default_sizes}{$track_id} = _u32($data, $pos + 16);
    }
}

sub set_init {
    my ($self, $data) = @_;
    my ($moov) = grep { $_->{type} eq 'moov' } _boxes($data);
    return unless $moov;

    $self->_parse_trex($data, $moov);
    for my $trak (_children($data, $moov)) {
        next unless $trak->{type} eq 'trak' && _is_audio_track($data, $trak);
        my $track_id = _track_id($data, $trak) or next;
        my $esds = _find_esds($data, $trak) or next;
        my $asc = _audio_specific_config($data, $esds) or next;
        next unless length($asc) >= 2;

        my $bits = unpack('B*', $asc);
        my $object_type = oct('0b' . substr($bits, 0, 5));
        my $frequency_index = oct('0b' . substr($bits, 5, 4));
        my $channel_config = oct('0b' . substr($bits, 9, 4));
        next if !$object_type || $object_type > 4 || $frequency_index == 15;

        @$self{qw(track_id profile frequency_index channel_config)} = (
            $track_id,
            $object_type - 1,
            $frequency_index,
            $channel_config,
        );
        $self->{log}->info(sprintf(
            'Twitch HLS fragmented MP4 AAC track: id=%d, profile=%d, rate-index=%d, channels=%d',
            $track_id, $object_type, $frequency_index, $channel_config,
        )) if $self->{log};
        return 1;
    }

    $self->{log}->warn(
        'Twitch HLS: no supported AAC audio track found in MP4 init segment'
    ) if $self->{log};
    return;
}

sub _tfhd {
    my ($self, $data, $box, $moof_start) = @_;
    my $pos = $box->{payload_start};
    return if $pos + 8 > $box->{end};
    my $version_flags = _u32($data, $pos);
    my $flags = $version_flags & 0x00ffffff;
    $pos += 4;
    my $track_id = _u32($data, $pos);
    $pos += 4;

    my $base = $moof_start;
    if ($flags & 0x000001) {
        return if $pos + 8 > $box->{end};
        $base = _u64($data, $pos);
        $pos += 8;
    }
    $pos += 4 if $flags & 0x000002;
    $pos += 4 if $flags & 0x000008;

    my $default_size = $self->{default_sizes}{$track_id} || 0;
    if ($flags & 0x000010) {
        return if $pos + 4 > $box->{end};
        $default_size = _u32($data, $pos);
        $pos += 4;
    }

    return {
        track_id     => $track_id,
        base         => $base,
        default_size => $default_size,
    };
}

sub _trun {
    my ($self, $data, $box, $tfhd, $cursor) = @_;
    my $pos = $box->{payload_start};
    return if $pos + 8 > $box->{end};
    my $version_flags = _u32($data, $pos);
    my $flags = $version_flags & 0x00ffffff;
    $pos += 4;
    my $count = _u32($data, $pos);
    $pos += 4;

    my $data_pos = $cursor;
    if ($flags & 0x000001) {
        return if $pos + 4 > $box->{end};
        my $offset = unpack('l>', substr($data, $pos, 4));
        $data_pos = $tfhd->{base} + $offset;
        $pos += 4;
    }
    $pos += 4 if $flags & 0x000004;

    my @samples;
    for (1 .. $count) {
        $pos += 4 if $flags & 0x000100;
        my $size = $tfhd->{default_size};
        if ($flags & 0x000200) {
            return if $pos + 4 > $box->{end};
            $size = _u32($data, $pos);
            $pos += 4;
        }
        $pos += 4 if $flags & 0x000400;
        $pos += 4 if $flags & 0x000800;
        return unless $size && $data_pos + $size <= length($data);
        push @samples, [$data_pos, $size];
        $data_pos += $size;
    }

    return (\@samples, $data_pos);
}

sub _adts_header {
    my ($self, $size) = @_;
    my $frame_length = $size + 7;
    return if $frame_length > 0x1fff;

    my $profile = $self->{profile};
    my $frequency = $self->{frequency_index};
    my $channels = $self->{channel_config};
    return pack('C7',
        0xff,
        0xf1,
        ($profile << 6) | ($frequency << 2) | (($channels >> 2) & 1),
        (($channels & 3) << 6) | (($frame_length >> 11) & 3),
        ($frame_length >> 3) & 0xff,
        (($frame_length & 7) << 5) | 0x1f,
        0xfc,
    );
}

sub extract {
    my ($self, $data) = @_;
    return '' unless defined $data && $self->{track_id};

    my @top = _boxes($data);
    my $out = '';
    for my $moof (grep { $_->{type} eq 'moof' } @top) {
        my ($mdat) = grep {
            $_->{type} eq 'mdat' && $_->{start} >= $moof->{end}
        } @top;
        my $cursor = $mdat ? $mdat->{payload_start} : undef;
        for my $traf (_children($data, $moof)) {
            next unless $traf->{type} eq 'traf';
            my $tfhd_box = _child($data, $traf, 'tfhd') or next;
            my $tfhd = $self->_tfhd($data, $tfhd_box, $moof->{start}) or next;
            next unless $tfhd->{track_id} == $self->{track_id};

            for my $trun (_children($data, $traf)) {
                next unless $trun->{type} eq 'trun';
                my ($samples, $next) = $self->_trun(
                    $data, $trun, $tfhd, $cursor,
                );
                next unless $samples;
                $cursor = $next;
                for my $sample (@$samples) {
                    my ($pos, $size) = @$sample;
                    my $header = $self->_adts_header($size) or next;
                    $out .= $header . substr($data, $pos, $size);
                }
            }
        }
    }

    return $out;
}

1;
