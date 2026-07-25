package Plugins::Twitch::HLSStream;

# Native HLS (MPEG-TS/ADTS) reader for Twitch audio renditions.  This is an
# IO::Handle because LMS consumes protocol handlers through sysread().

use strict;
use warnings;
use bytes;

use base qw(IO::Handle);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Player::ProtocolHandlers;
use Slim::Formats::Playlists;
use Slim::Utils::Errno;
use Slim::Utils::Log qw(logger);
use Slim::Utils::Versions ();
use Time::HiRes qw(time);
use URI;

use Plugins::Twitch::HLSPlaylist ();

my $log = logger('plugin.twitch');

Slim::Player::ProtocolHandlers->registerHandler('twitchhls', __PACKAGE__);
Slim::Formats::Playlists->registerParser(
    'twitchhlspl',
    'Plugins::Twitch::HLSPlaylist',
);

use constant {
    TS_PACKET_SIZE  => 188,
    HTTP_TIMEOUT    => 20,
    MAX_ADTS_BUFFER => 2_000_000,
};

# LMS releases before 7.9.1 retry an IO handler only for EINTR.  Newer LMS
# releases correctly use EWOULDBLOCK for an asynchronously filled handle.
use constant IO_SELECT_FIXED =>
    Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0;

sub isRemote         { 1 }
sub isAudio          { 1 }
sub canDirectStream  { 0 }
sub canSeek          { 0 }
sub contentType      { 'audio/aac' }
sub formatOverride   { 'aac' }

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
    ${*$self}{adts_buffer}  = '';
    ${*$self}{cc}           = {};
    ${*$self}{started}      = 0;
    ${*$self}{next_playlist}= 0;

    $log->info("Twitch HLS reader opened: $url");
    $self->_fetch_playlist;
    return $self;
}

sub close {
    my ($self) = @_;
    ${*$self}{closed} = 1;
    delete ${*$self}{playlist_request};
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
        ${*$self}{cc} = {};
        delete ${*$self}{audio_pid};
        $log->info('Twitch HLS playlist sequence restarted');
    }
    ${*$self}{last_sequence} = $sequence;

    my $endlist = $body =~ /#EXT-X-ENDLIST/;
    my @new;
    my ($duration, $last_duration, $discontinuity, $index) = (0, 6, 0, 0);
    for my $line (split /\r?\n/, $body) {
        if ($line =~ /^#EXT-X-DISCONTINUITY/) { $discontinuity = 1; next; }
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
        };
        $discontinuity = 0;
        $last_duration = $duration if $duration;
    }

    # Start a live stream close to its live edge, rather than replaying a
    # potentially long initial playlist window.
    if (!${*$self}{started} && !$endlist && @new > 3) {
        @new = splice @new, -3;
    }
    ${*$self}{started} = 1 if @new;
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
    for my $segment (@$segments) {
        next if $segment->{fetching} || defined $segment->{aac};
        $segment->{fetching} = 1;
        ${*$self}{segment_request} = $self->_request($segment->{url}, sub {
            my ($ts) = @_;
            delete ${*$self}{segment_request};
            delete $segment->{fetching};
            ${*$self}{cc} = {} if $segment->{discontinuity};
            $segment->{aac} = $self->_extract_adts($ts);
            $log->info(sprintf 'Twitch HLS segment: %d TS bytes, %d ADTS bytes',
                length($ts || ''), length($segment->{aac}));
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

sub _payload {
    my ($packet) = @_;
    return unless length($packet) == TS_PACKET_SIZE && substr($packet, 0, 1) eq "\x47";
    my ($b1, $b2, $b3) = unpack('xC3', $packet);
    my $adaptation = ($b3 >> 4) & 3;
    return if !$adaptation;
    my $offset = 4;
    if ($adaptation == 2 || $adaptation == 3) {
        my $length = ord(substr($packet, $offset, 1));
        $offset += 1 + $length;
    }
    return if $offset >= TS_PACKET_SIZE || !($adaptation == 1 || $adaptation == 3);
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
    my $length = ((ord(substr($payload, 1, 1)) & 0x0f) << 8) | ord(substr($payload, 2, 1));
    return if $length < 4 || $length > 4093 || length($payload) < 3 + $length;
    return substr($payload, 0, 3 + $length);
}

sub _find_pids {
    my ($self, $ts) = @_;
    my $pmt_pid;
    for (my $i = 0; $i + TS_PACKET_SIZE <= length($ts); $i += TS_PACKET_SIZE) {
        my $h = _payload(substr($ts, $i, TS_PACKET_SIZE)) or next;
        next unless $h->{pid} == 0;
        my $section = _psi_section($h->{payload}, $h->{pusi}) or next;
        next unless ord(substr($section, 0, 1)) == 0;
        for (my $p = 8; $p + 4 <= length($section) - 4; $p += 4) {
            my $program = unpack('n', substr($section, $p, 2));
            if ($program) { $pmt_pid = ((ord(substr($section, $p + 2, 1)) & 0x1f) << 8) | ord(substr($section, $p + 3, 1)); last; }
        }
        last if defined $pmt_pid;
    }
    return unless defined $pmt_pid;
    for (my $i = 0; $i + TS_PACKET_SIZE <= length($ts); $i += TS_PACKET_SIZE) {
        my $h = _payload(substr($ts, $i, TS_PACKET_SIZE)) or next;
        next unless $h->{pid} == $pmt_pid;
        my $section = _psi_section($h->{payload}, $h->{pusi}) or next;
        next unless ord(substr($section, 0, 1)) == 2 && length($section) >= 16;
        my $pos = 12 + (((ord(substr($section, 10, 1)) & 0x0f) << 8) | ord(substr($section, 11, 1)));
        my $end = length($section) - 4;
        while ($pos + 5 <= $end) {
            my $type = ord(substr($section, $pos, 1));
            my $pid = ((ord(substr($section, $pos + 1, 1)) & 0x1f) << 8) | ord(substr($section, $pos + 2, 1));
            my $len = ((ord(substr($section, $pos + 3, 1)) & 0x0f) << 8) | ord(substr($section, $pos + 4, 1));
            return $pid if $type == 0x0f; # AAC with ADTS framing
            $pos += 5 + $len;
        }
    }
    return;
}

sub _extract_adts {
    my ($self, $ts) = @_;
    return '' unless defined $ts;
    ${*$self}{audio_pid} //= $self->_find_pids($ts);
    my $pid = ${*$self}{audio_pid};
    unless (defined $pid) {
        unless (${*$self}{reported_no_audio_pid}++) {
            $log->warn('Twitch HLS: no AAC PID found in PAT/PMT; stream is not MPEG-TS AAC');
        }
        return '';
    }
    $log->info(sprintf 'Twitch HLS AAC PID: 0x%04x', $pid)
        unless ${*$self}{reported_audio_pid}++;

    my $pes = '';
    for (my $i = 0; $i + TS_PACKET_SIZE <= length($ts); $i += TS_PACKET_SIZE) {
        my $h = _payload(substr($ts, $i, TS_PACKET_SIZE)) or next;
        next unless $h->{pid} == $pid;
        if (defined ${*$self}{cc}{$pid} && $h->{cc} != ((${*$self}{cc}{$pid} + 1) & 0x0f)) {
            $log->debug("Twitch TS continuity jump on audio PID $pid");
        }
        ${*$self}{cc}{$pid} = $h->{cc};
        my $payload = $h->{payload};
        if ($h->{pusi} && substr($payload, 0, 3) eq "\x00\x00\x01") {
            next unless length($payload) >= 9;
            $payload = substr($payload, 9 + ord(substr($payload, 8, 1)));
        }
        $pes .= $payload;
    }

    my $buffer = ${*$self}{adts_buffer} . $pes;
    my $out = '';
    while (length($buffer) >= 7) {
        my $sync = index($buffer, "\xff");
        last if $sync < 0;
        substr($buffer, 0, $sync, '') if $sync;
        last if length($buffer) < 7;
        if ((ord(substr($buffer, 1, 1)) & 0xf6) != 0xf0) { substr($buffer, 0, 1, ''); next; }
        my $length = ((ord(substr($buffer, 3, 1)) & 3) << 11) | (ord(substr($buffer, 4, 1)) << 3) | ((ord(substr($buffer, 5, 1)) & 0xe0) >> 5);
        if ($length < 7 || $length > 8192) { substr($buffer, 0, 1, ''); next; }
        last if length($buffer) < $length;
        $out .= substr($buffer, 0, $length, '');
    }
    substr($buffer, 0, length($buffer) - 500_000, '') if length($buffer) > MAX_ADTS_BUFFER;
    ${*$self}{adts_buffer} = $buffer;
    return $out;
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
