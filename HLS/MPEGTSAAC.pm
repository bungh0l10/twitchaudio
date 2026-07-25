package Plugins::Twitch::HLS::MPEGTSAAC;

use strict;
use warnings;
use bytes;

use constant {
    TS_PACKET_SIZE  => 188,
    MAX_ADTS_BUFFER => 2_000_000,
};

sub new {
    my ($class, $args) = @_;
    return bless {
        log         => $args->{log},
        adts_buffer => '',
        cc          => {},
    }, $class;
}

sub _payload {
    my ($packet) = @_;
    return unless length($packet) == TS_PACKET_SIZE
        && substr($packet, 0, 1) eq "\x47";

    my ($b1, $b2, $b3) = unpack('xC3', $packet);
    my $adaptation = ($b3 >> 4) & 3;
    return unless $adaptation;

    my $offset = 4;
    if ($adaptation == 2 || $adaptation == 3) {
        my $length = ord(substr($packet, $offset, 1));
        $offset += 1 + $length;
    }
    return if $offset >= TS_PACKET_SIZE
        || !($adaptation == 1 || $adaptation == 3);

    return {
        pid     => (($b1 & 0x1f) << 8) | $b2,
        pusi    => ($b1 >> 6) & 1,
        cc      => $b3 & 0x0f,
        payload => substr($packet, $offset),
    };
}

sub _psi_section {
    my ($payload, $pusi) = @_;
    return unless $pusi && length($payload);

    my $pointer = ord(substr($payload, 0, 1));
    $payload = substr($payload, 1 + $pointer);
    return unless length($payload) >= 3;

    my $length = ((ord(substr($payload, 1, 1)) & 0x0f) << 8)
        | ord(substr($payload, 2, 1));
    return if $length < 4 || $length > 4093
        || length($payload) < 3 + $length;

    return substr($payload, 0, 3 + $length);
}

sub _find_audio_pid {
    my ($self, $ts) = @_;
    my $pmt_pid;

    for (my $i = 0; $i + TS_PACKET_SIZE <= length($ts); $i += TS_PACKET_SIZE) {
        my $h = _payload(substr($ts, $i, TS_PACKET_SIZE)) or next;
        next unless $h->{pid} == 0;
        my $section = _psi_section($h->{payload}, $h->{pusi}) or next;
        next unless ord(substr($section, 0, 1)) == 0;

        for (my $p = 8; $p + 4 <= length($section) - 4; $p += 4) {
            my $program = unpack('n', substr($section, $p, 2));
            if ($program) {
                $pmt_pid = ((ord(substr($section, $p + 2, 1)) & 0x1f) << 8)
                    | ord(substr($section, $p + 3, 1));
                last;
            }
        }
        last if defined $pmt_pid;
    }
    return unless defined $pmt_pid;

    for (my $i = 0; $i + TS_PACKET_SIZE <= length($ts); $i += TS_PACKET_SIZE) {
        my $h = _payload(substr($ts, $i, TS_PACKET_SIZE)) or next;
        next unless $h->{pid} == $pmt_pid;
        my $section = _psi_section($h->{payload}, $h->{pusi}) or next;
        next unless ord(substr($section, 0, 1)) == 2
            && length($section) >= 16;

        my $pos = 12
            + (((ord(substr($section, 10, 1)) & 0x0f) << 8)
            | ord(substr($section, 11, 1)));
        my $end = length($section) - 4;
        while ($pos + 5 <= $end) {
            my $type = ord(substr($section, $pos, 1));
            my $pid = ((ord(substr($section, $pos + 1, 1)) & 0x1f) << 8)
                | ord(substr($section, $pos + 2, 1));
            my $length = ((ord(substr($section, $pos + 3, 1)) & 0x0f) << 8)
                | ord(substr($section, $pos + 4, 1));
            return $pid if $type == 0x0f;
            $pos += 5 + $length;
        }
    }

    return;
}

sub extract {
    my ($self, $ts) = @_;
    return '' unless defined $ts;

    $self->{audio_pid} //= $self->_find_audio_pid($ts);
    my $pid = $self->{audio_pid};
    unless (defined $pid) {
        if (!$self->{reported_no_audio_pid}++) {
            $self->{log}->warn(
                'Twitch HLS: no AAC PID found in MPEG-TS segment'
            ) if $self->{log};
        }
        return '';
    }

    if (!$self->{reported_audio_pid}++) {
        $self->{log}->info(sprintf 'Twitch HLS AAC PID: 0x%04x', $pid)
            if $self->{log};
    }

    # Twitch restarts continuity counters at segment boundaries.
    $self->{cc} = {};
    my $pes = '';
    for (my $i = 0; $i + TS_PACKET_SIZE <= length($ts); $i += TS_PACKET_SIZE) {
        my $h = _payload(substr($ts, $i, TS_PACKET_SIZE)) or next;
        next unless $h->{pid} == $pid;

        if (defined $self->{cc}{$pid}
            && $h->{cc} != (($self->{cc}{$pid} + 1) & 0x0f))
        {
            $self->{log}->debug("Twitch TS continuity jump on audio PID $pid")
                if $self->{log};
        }
        $self->{cc}{$pid} = $h->{cc};

        my $payload = $h->{payload};
        if ($h->{pusi} && substr($payload, 0, 3) eq "\x00\x00\x01") {
            next unless length($payload) >= 9;
            $payload = substr($payload, 9 + ord(substr($payload, 8, 1)));
        }
        $pes .= $payload;
    }

    my $buffer = $self->{adts_buffer} . $pes;
    my $out = '';
    while (length($buffer) >= 7) {
        my $sync = index($buffer, "\xff");
        last if $sync < 0;
        substr($buffer, 0, $sync, '') if $sync;
        last if length($buffer) < 7;
        if ((ord(substr($buffer, 1, 1)) & 0xf6) != 0xf0) {
            substr($buffer, 0, 1, '');
            next;
        }

        my $length = ((ord(substr($buffer, 3, 1)) & 3) << 11)
            | (ord(substr($buffer, 4, 1)) << 3)
            | ((ord(substr($buffer, 5, 1)) & 0xe0) >> 5);
        if ($length < 7 || $length > 8192) {
            substr($buffer, 0, 1, '');
            next;
        }
        last if length($buffer) < $length;
        $out .= substr($buffer, 0, $length, '');
    }

    substr($buffer, 0, length($buffer) - 500_000, '')
        if length($buffer) > MAX_ADTS_BUFFER;
    $self->{adts_buffer} = $buffer;
    return $out;
}

1;
