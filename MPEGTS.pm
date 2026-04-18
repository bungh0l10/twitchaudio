package Plugins::Twitch::MPEGTS;

use strict;
use warnings;
use bytes;

use parent qw(Slim::Utils::Accessor);

use Slim::Utils::Log;

my $log = logger('plugin.twitch');

# --- TS Constants ----------------------------------------------------------

use constant TS_PACKET_SIZE => 188;
use constant SYNC_BYTE      => 0x47;

# Header Offsets
use constant {
    TS_HEADER_SIZE => 4,
    TS_PID_OFS     => 1,
    TS_FLAGS_OFS   => 3,
    TS_AF_LEN_OFS  => 4,
};

# Bit masks
use constant {
    PID_MASK        => 0x1FFF,
    CC_MASK         => 0x0F,
    ADAPTATION_FLAG => 0x20,
    PUSI_MASK       => 0x4000,
};

# States
use constant {
    STATE_SYNC  => 0,
    STATE_PAT   => 1,
    STATE_PMT   => 2,
    STATE_AUDIO => 3,
};

# Table parsing
use constant {
    POINTER_FIELD_SIZE => 1,
    CRC_SIZE           => 4,
};

# Stream types (AAC only)
use constant STREAM_AAC => 0x0F;

# PES
use constant {
    PES_MIN_HEADER => 9,
    PES_FLAGS_OFS  => 7,
    PES_HDRLEN_OFS => 8,
    PES_DATA_OFS   => 9,
    PTS_FLAG       => 0x80,
    PTS_SIZE       => 5,
};

# --- Accessors -------------------------------------------------------------

__PACKAGE__->mk_accessor('rw', qw(
    bitrate samplerate channels format url _context
));

# --- Constructor -----------------------------------------------------------

sub new {
    my ($class, $url) = @_;

    my $self = $class->SUPER::new;

    $self->init_accessor(
        url      => $url,
        _context => {},
    );

    return bless $self, $class;
}

sub flush {
    my ($self) = @_;
    $self->_context({});
    return;
}

sub addBytes {
    my ($self, $data) = @_;

    my $buf = ref $data ? $$data : $data;

    my $ctx = $self->_context;
    $ctx->{inBuf} //= '';
    $ctx->{inBuf} .= $buf;

    return;
}

# --- Core ------------------------------------------------------------------

sub getAudio {
    my ($self, $out_ref) = @_;

    my $ctx = $self->_context;

    $ctx->{inBuf} //= '';
    $ctx->{state} //= STATE_SYNC;

    while (length($ctx->{inBuf}) >= TS_PACKET_SIZE) {

        # --- Sync --------------------------------------------------------
        if ($ctx->{state} == STATE_SYNC) {

            my $pos = _find_sync($ctx->{inBuf});

            if ($pos < 0) {
                substr(
                    $ctx->{inBuf},
                    0,
                    length($ctx->{inBuf}) - TS_PACKET_SIZE,
                    ''
                );
                last;
            }

            substr($ctx->{inBuf}, 0, $pos, '');
            $ctx->{state} = STATE_PAT;
        }

        last if length($ctx->{inBuf}) < TS_PACKET_SIZE;

        my $packet = substr($ctx->{inBuf}, 0, TS_PACKET_SIZE, '');

        unless (ord(substr($packet, 0, 1)) == SYNC_BYTE) {
            $ctx->{state} = STATE_SYNC;
            next;
        }

        my $pid   = unpack('n', substr($packet, TS_PID_OFS, 2)) & PID_MASK;
        my $flags = ord(substr($packet, TS_FLAGS_OFS, 1));
        my $cc    = $flags & CC_MASK;

        # --- Continuity Counter -----------------------------------------
        if (defined $ctx->{cc}->{$pid}) {
            my $expected = ($ctx->{cc}->{$pid} + 1) & CC_MASK;

            if ($expected != $cc) {
                $log->debug("CC discontinuity pid=$pid");
                delete $ctx->{pes}->{$pid};
            }
        }
        $ctx->{cc}->{$pid} = $cc;

        # --- Adaptation Field (SAFE) ------------------------------------
        my $ofs = TS_HEADER_SIZE;

        if ($flags & ADAPTATION_FLAG) {

            next if length($packet) <= TS_AF_LEN_OFS;

            my $len = ord(substr($packet, TS_AF_LEN_OFS, 1));

            next if length($packet) < TS_HEADER_SIZE + 1 + $len;

            $ofs += POINTER_FIELD_SIZE + $len;
        }

        my $payload = substr($packet, $ofs);

        next unless length $payload;

        my $pusi = unpack('n', substr($packet, TS_PID_OFS, 2)) & PUSI_MASK;

        # --- PAT ---------------------------------------------------------
        if ($ctx->{state} == STATE_PAT && $pid == 0) {
            _parse_pat($ctx, $payload);
            next;
        }

        # --- PMT ---------------------------------------------------------
        if (
            $ctx->{state} == STATE_PMT
            && defined $ctx->{pidPMT}
            && $pid == $ctx->{pidPMT}
        ) {
            _parse_pmt($ctx, $payload);
            next;
        }

        # --- AUDIO (AAC only) -------------------------------------------
        if (
            $ctx->{state} == STATE_AUDIO
            && defined $ctx->{stream}
            && $pid == $ctx->{stream}->{pid}
        ) {

            my $pes = $ctx->{pes}->{$pid} //= {
                data => q{},
                pts  => undef,
            };

            if ($pusi) {

                _flush_pes($self, $pes, $out_ref);

                %{$pes} = ( data => q{}, pts => undef );

                _parse_pes_header($pes, $payload);
            }
            else {
                $pes->{data} .= $payload;
            }
        }
    }

    # --- IMPORTANT: flush remaining PES ------------------------------------
    for my $pid (keys %{ $ctx->{pes} || {} }) {
        _flush_pes($self, $ctx->{pes}->{$pid}, $out_ref);
    }

    return 1;
}

# --- PAT -------------------------------------------------------------------

sub _parse_pat {
    my ($ctx, $payload) = @_;

    return if length($payload) < POINTER_FIELD_SIZE;

    my $pointer = ord(substr($payload, 0, 1));
    my $section  = substr($payload, POINTER_FIELD_SIZE + $pointer);

    return if length($section) < 12;

    my $pidPMT =
        unpack('n', substr($section, 10, 2)) & PID_MASK;

    $ctx->{pidPMT} = $pidPMT;
    $ctx->{state}  = STATE_PMT;

    return;
}

# --- PMT -------------------------------------------------------------------

sub _parse_pmt {
    my ($ctx, $payload) = @_;

    my $pointer = ord(substr($payload, 0, 1));
    my $section  = substr($payload, POINTER_FIELD_SIZE + $pointer);

    return if length($section) < 12;

    my $prog_info_len =
        unpack('n', substr($section, 10, 2)) & 0x03FF;

    my $pos = 12 + $prog_info_len;

    # reset stream state on PMT change
    delete $ctx->{stream};
    $ctx->{pes} = {};
    $ctx->{cc}  = {};

    while ($pos < length($section) - CRC_SIZE) {

        my $type = ord(substr($section, $pos, 1));
        my $pid  = unpack('n', substr($section, $pos + 1, 2)) & PID_MASK;
        my $len  = unpack('n', substr($section, $pos + 3, 2)) & 0x03FF;

        if ($type == STREAM_AAC) {
            $ctx->{stream} = { format => 'aac', pid => $pid };
        }

        $pos += 5 + $len;
    }

    $ctx->{state} = STATE_AUDIO if $ctx->{stream};

    return;
}

# --- PES -------------------------------------------------------------------

sub _parse_pes_header {
    my ($pes, $payload) = @_;

    return if length($payload) < PES_MIN_HEADER;

    my $flags   = ord(substr($payload, PES_FLAGS_OFS, 1));
    my $hdr_len = ord(substr($payload, PES_HDRLEN_OFS, 1));

    if ($flags & PTS_FLAG) {
        $pes->{pts} =
            _decode_pts(substr($payload, PES_DATA_OFS, PTS_SIZE));
    }

    $pes->{data} .= substr($payload, PES_DATA_OFS + $hdr_len);

    return;
}

sub _flush_pes {
    my ($self, $pes, $out_ref) = @_;

    return unless length $pes->{data};

    ${$out_ref} .= $pes->{data};

    return;
}

# --- Helpers ---------------------------------------------------------------

sub _decode_pts {
    my ($b) = @_;

    return
          ((ord(substr($b,0,1)) & 0x0E) << 29)
        | ( ord(substr($b,1,1)) << 22 )
        | ((ord(substr($b,2,1)) & 0xFE) << 14)
        | ( ord(substr($b,3,1)) << 7 )
        | ((ord(substr($b,4,1)) & 0xFE) >> 1);
}

sub _find_sync {
    my ($buf) = @_;

    my $len = length($buf);

    for (my $i = 0; $i < $len - TS_PACKET_SIZE * 2; $i++) {

        next unless ord(substr($buf, $i, 1)) == SYNC_BYTE;

        my $ok = 1;

        for my $n (1 .. 2) {
            my $pos = $i + $n * TS_PACKET_SIZE;

            if ($pos >= $len
                || ord(substr($buf, $pos, 1)) != SYNC_BYTE) {
                $ok = 0;
                last;
            }
        }

        return $i if $ok;
    }

    return -1;
}

1;