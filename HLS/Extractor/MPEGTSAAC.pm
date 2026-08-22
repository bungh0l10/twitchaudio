package Plugins::Twitch::HLS::Extractor::MPEGTSAAC;

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

sub set_init { 1 }

sub continuity_info {
    my ($self) = @_;
    return $self->{last_continuity};
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

sub _drain_psi_sections {
    my ($buffer, $sections) = @_;

    while (length($$buffer) >= 3) {
        if (ord(substr($$buffer, 0, 1)) == 0xff) {
            $$buffer = '';
            last;
        }

        my $length = ((ord(substr($$buffer, 1, 1)) & 0x0f) << 8)
            | ord(substr($$buffer, 2, 1));
        if ($length < 4 || $length > 4093) {
            substr($$buffer, 0, 1, '');
            next;
        }

        my $total = 3 + $length;
        last if length($$buffer) < $total;
        push @$sections, substr($$buffer, 0, $total, '');
    }

    return;
}

sub _psi_sections {
    my ($ts, $pid) = @_;
    my @sections;
    my $buffer = '';
    my $assembling = 0;
    my $last_cc;

    for (my $i = 0; $i + TS_PACKET_SIZE <= length($ts); $i += TS_PACKET_SIZE) {
        my $h = _payload(substr($ts, $i, TS_PACKET_SIZE)) or next;
        next unless $h->{pid} == $pid;

        if (defined $last_cc && $h->{cc} != (($last_cc + 1) & 0x0f)) {
            $buffer = '';
            $assembling = 0;
        }
        $last_cc = $h->{cc};

        my $payload = $h->{payload};
        next unless length($payload);

        if ($h->{pusi}) {
            my $pointer = ord(substr($payload, 0, 1));
            next if 1 + $pointer > length($payload);

            if ($assembling && $pointer) {
                $buffer .= substr($payload, 1, $pointer);
                _drain_psi_sections(\$buffer, \@sections);
            }

            # A new section starts after the pointer field. Any incomplete
            # previous section is malformed and must not contaminate it.
            $buffer = substr($payload, 1 + $pointer);
            $assembling = 1;
        } elsif ($assembling) {
            $buffer .= $payload;
        } else {
            next;
        }

        _drain_psi_sections(\$buffer, \@sections);
        $assembling = 0 unless length($buffer);
    }

    return @sections;
}

sub _find_audio_pid {
    my ($self, $ts) = @_;
    my $pmt_pid;

    for my $section (_psi_sections($ts, 0)) {
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

    for my $section (_psi_sections($ts, $pmt_pid)) {
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
    delete $self->{last_continuity};
    return '' unless defined $ts;

    $self->{audio_pid} //= $self->_find_audio_pid($ts);
    my $pid = $self->{audio_pid};
    unless (defined $pid) {
        if (!$self->{reported_no_audio_pid}++) {
            $self->{log}->error(
                'Twitch HLS: no AAC PID found in MPEG-TS segment'
            ) if $self->{log};
        }
        return '';
    }

    my $pes = '';
    my ($first_cc, $last_cc, $audio_packets, $continuity_jumps)
        = (undef, undef, 0, 0);
    my $ts_length = length($ts);
    for (my $i = 0; $i + TS_PACKET_SIZE <= $ts_length; $i += TS_PACKET_SIZE) {
        # Read only the four-byte transport header before deciding whether the
        # packet belongs to the audio PID. This avoids copying every complete
        # TS packet and allocating a temporary payload hash on the hot path.
        next unless substr($ts, $i, 1) eq "\x47";
        my ($b1, $b2, $b3) = unpack('C3', substr($ts, $i + 1, 3));
        my $packet_pid = (($b1 & 0x1f) << 8) | $b2;
        next unless $packet_pid == $pid;

        my $adaptation = ($b3 >> 4) & 3;
        next unless $adaptation == 1 || $adaptation == 3;

        my $packet_end = $i + TS_PACKET_SIZE;
        my $payload_offset = $i + 4;
        if ($adaptation == 3) {
            # The packet is complete, so the length byte itself is present.
            # Reject lengths which consume bytes beyond this packet; accepting
            # them would accidentally read payload from the following packet.
            my $adaptation_length = ord(substr($ts, $payload_offset, 1));
            $payload_offset += 1 + $adaptation_length;
            next if $payload_offset >= $packet_end;
        }

        my $cc = $b3 & 0x0f;

        if (defined $self->{cc}{$pid}
            && $cc != (($self->{cc}{$pid} + 1) & 0x0f))
        {
            $continuity_jumps++;
            $self->{log}->debug("Twitch TS continuity jump on audio PID $pid")
                if $self->{log};
        }
        $first_cc = $cc unless defined $first_cc;
        $last_cc = $cc;
        $audio_packets++;
        $self->{cc}{$pid} = $cc;

        my $payload_length = $packet_end - $payload_offset;
        if (($b1 & 0x40)
            && $payload_length >= 3
            && substr($ts, $payload_offset, 3) eq "\x00\x00\x01")
        {
            # A PES header has nine fixed bytes followed by the declared
            # optional-header bytes. Never let a malformed length cross the
            # current TS packet boundary.
            next if $payload_length < 9;
            my $pes_header_length
                = 9 + ord(substr($ts, $payload_offset + 8, 1));
            next if $pes_header_length > $payload_length;
            $payload_offset += $pes_header_length;
            $payload_length -= $pes_header_length;
        }

        $pes .= substr($ts, $payload_offset, $payload_length)
            if $payload_length;
    }

    $self->{last_continuity} = {
        pid     => $pid,
        first   => $first_cc,
        last    => $last_cc,
        packets => $audio_packets,
        jumps   => $continuity_jumps,
    } if $audio_packets;

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
