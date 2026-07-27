package Plugins::Twitch::HLS::Playlist;

use strict;
use warnings;

use URI;

sub _https_url {
    my ($reference, $base_url) = @_;
    return unless defined $reference && length($reference);

    my $uri = URI->new_abs($reference, $base_url);
    return unless lc($uri->scheme || '') eq 'https';
    return unless defined $uri->host && length($uri->host);
    return $uri->as_string;
}

sub resolve_https_url {
    my ($class, $reference, $base_url) = @_;
    return _https_url($reference, $base_url);
}

sub parse {
    my ($class, $body, $base_url) = @_;
    return unless defined $body && $body =~ /#EXTM3U/;
    return unless _https_url($base_url, $base_url);

    my ($sequence) = $body =~ /#EXT-X-MEDIA-SEQUENCE:(\d+)/;
    $sequence //= 0;

    my ($playlist_type) = $body =~ /#EXT-X-PLAYLIST-TYPE:([A-Z]+)/i;
    $playlist_type = uc($playlist_type // '');

    my ($target_duration) = $body =~ /#EXT-X-TARGETDURATION:([\d.]+)/;
    my ($twitch_elapsed) = $body =~ /#EXT-X-TWITCH-ELAPSED-SECS:([\d.]+)/;
    my ($twitch_total) = $body =~ /#EXT-X-TWITCH-TOTAL-SECS:([\d.]+)/;
    my $endlist = $body =~ /#EXT-X-ENDLIST/ ? 1 : 0;

    my @segments;
    my $window_start = defined $twitch_elapsed ? $twitch_elapsed + 0 : 0;
    my ($duration, $elapsed, $discontinuity, $index)
        = (0, $window_start, 0, 0);
    my $init_url;

    for my $line (split /\r?\n/, $body) {
        if ($line =~ /^#EXT-X-DISCONTINUITY/) {
            $discontinuity = 1;
            next;
        }
        if ($line =~ /^#EXT-X-MAP:.*\bURI="([^"]+)"/) {
            $init_url = _https_url($1, $base_url);
            return unless $init_url;
            next;
        }
        if ($line =~ /^#EXTINF:([\d.]+)/) {
            $duration = $1 + 0;
            next;
        }
        next if $line =~ /^#/ || $line !~ /\S/;

        my $url = _https_url($line, $base_url);
        return unless $url;
        push @segments, {
            sequence      => $sequence + $index++,
            url           => $url,
            duration      => $duration,
            start_time    => $elapsed,
            init_url      => $init_url,
            container     => $init_url ? 'mp4' : undef,
            discontinuity => $discontinuity,
            muted         => $url =~ m{(?:^|/)[^/?#]*-muted\.(?:ts|mp4)(?:[?#]|$)}i
                ? 1 : 0,
        };

        $elapsed += $duration;
        $discontinuity = 0;
        $duration = 0;
    }

    my $total_duration = defined $twitch_total
        ? $twitch_total + 0
        : ($endlist ? $elapsed : undef);

    return bless {
        media_sequence  => $sequence,
        playlist_type   => $playlist_type,
        endlist         => $endlist,
        target_duration => ($target_duration // 6) + 0,
        total_duration  => $total_duration,
        window_start    => $window_start,
        window_duration => $elapsed - $window_start,
        segments        => \@segments,
    }, $class;
}

sub media_sequence  { $_[0]->{media_sequence} }
sub playlist_type   { $_[0]->{playlist_type} }
sub endlist         { $_[0]->{endlist} }
sub target_duration { $_[0]->{target_duration} }
sub total_duration  { $_[0]->{total_duration} }
sub window_duration { $_[0]->{window_duration} }
sub segments        { $_[0]->{segments} }

sub is_seekable {
    my ($self) = @_;
    return $self->{endlist}
        || ($self->{playlist_type} eq 'EVENT'
            && defined $self->{total_duration}
            && $self->{total_duration} > 0);
}

sub reload_after {
    my ($self) = @_;
    my $duration = $self->{target_duration};
    return $duration > 3 ? $duration - 2 : 1;
}

sub is_complete {
    my ($self) = @_;
    return 1 if $self->{endlist};
    return 0 unless $self->{playlist_type} eq 'EVENT'
        && defined $self->{total_duration}
        && @{ $self->{segments} };

    my $last = $self->{segments}[-1];
    return $last->{start_time} + $last->{duration}
        >= $self->{total_duration} - 0.01;
}

sub segment_at {
    my ($self, $time) = @_;
    return unless @{ $self->{segments} };
    $time //= 0;

    for my $segment (@{ $self->{segments} }) {
        return $segment
            if $segment->{start_time} + $segment->{duration} > $time;
    }

    return $self->{segments}[-1];
}

1;
