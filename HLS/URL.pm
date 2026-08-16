package Plugins::Twitch::HLS::URL;

use strict;
use warnings;

# LMS replaces the logical twitch: track with the resolved twitchhls: track.
# Carry the logical identity in that URL so it survives independently of the
# short-lived cache entry used for legacy URLs.
sub to_internal {
    my ($url, $media_id) = @_;
    return unless defined $url && defined $media_id;
    return unless $url =~ s{^https:}{twitchhls:}i;
    return unless $media_id =~ /^(?:vod:\d{1,20}|live:[a-z0-9_]{1,25})$/;

    return "$url|twitch=$media_id";
}

sub media_id {
    my ($url) = @_;
    return unless defined $url;

    return $1 if $url =~ /\|twitch=((?:vod:\d{1,20})|(?:live:[a-z0-9_]{1,25}))$/;
    return;
}

sub playlist_url {
    my ($url) = @_;
    return unless defined $url;

    $url =~ s/\|twitch=(?:vod:\d{1,20}|live:[a-z0-9_]{1,25})$//;
    $url =~ s/\|$//; # compatibility with URLs produced by older releases
    return unless $url =~ s{^twitchhls:}{https:}i;

    return $url;
}

1;
