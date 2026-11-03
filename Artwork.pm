package Plugins::Twitch::Artwork;

use strict;
use warnings;

use Slim::Web::Graphics ();
use Slim::Web::ImageProxy ();

# Use one full-size profile URL in menus and playback metadata. Its new cache
# identity also avoids ImageProxy/browser results made from the old 300px source.
# Material and SqueezePlay still request their display size through ImageProxy.
my $profile_url = qr{^(https?://static-cdn\.jtvnw\.net/(?:jtv_user_pictures|user-default-pictures-uv)/[^/?#]*profile_image[^/?#]*-)(\d+)x(\d+)(\.(?:png|jpe?g|gif)(?:[?#].*)?)$}i;
my $vod_url = qr{^(https?://static-cdn\.jtvnw\.net/cf_vods/[^?#]+/thumb/[^/?#]+-)(\d+)x(\d+)(\.(?:png|jpe?g)(?:[?#].*)?)$}i;

sub init {
    for my $match ($profile_url, $vod_url) {
        Slim::Web::ImageProxy->registerHandler(
            match => $match,
            func  => \&url_for_size,
        );
    }
}

sub metadata_url {
    my ($url) = @_;
    return $url unless defined $url && $url =~ $profile_url;
    my ($prefix, $width, $height, $suffix) = ($1, $2, $3, $4);
    return $url unless $width > 0 && $width == $height;
    return $prefix . '600x600' . $suffix;
}

sub url_for_size {
    my ($url, $spec) = @_;
    return $url unless defined $url;

    my ($width, $height, $mode) = Slim::Web::Graphics->parseSpec($spec || '');
    # LMS permits X for an unconstrained dimension. Material's gallery removes
    # the size altogether: it should receive the full profile, not the old 300px
    # source. metadata_url leaves VOD URLs and their aspect ratio untouched.
    $width = undef unless defined $width && $width =~ /^[1-9]\d*$/;
    $height = undef unless defined $height && $height =~ /^[1-9]\d*$/;
    return metadata_url($url) unless $width || $height;

    if ($url =~ $profile_url) {
        my ($prefix, $original_width, $original_height, $suffix) = ($1, $2, $3, $4);
        return $url unless $original_width > 0 && $original_width == $original_height;

        my $dimension = $width || $height;
        if ($width && $height) {
            # SqueezePlay's m mode keeps the square source proportional inside
            # its display frame; a 480x272 frame therefore needs only 272px.
            $dimension = ($mode || '') eq 'm'
                ? ($width < $height ? $width : $height)
                : ($width > $height ? $width : $height);
        }
        my $size = Slim::Web::ImageProxy->getRightSize(
            $dimension . 'x' . $dimension,
            { 70 => 70, 150 => 150, 300 => 300, 600 => 600 },
        ) || 600;
        return $prefix . $size . 'x' . $size . $suffix;
    }

    if ($url =~ $vod_url) {
        my ($prefix, $original_width, $original_height, $suffix) = ($1, $2, $3, $4);
        # Only select verified 16:9 Twitch thumbnail variants. Leave other
        # aspect ratios alone rather than changing an existing image's shape.
        return $url unless $original_width > 0 && $original_width * 9 == $original_height * 16;

        my $needed_width = $width;
        my $from_height = $height ? $height * 16 / 9 : undef;
        if ($from_height && (!$needed_width
            || (($mode || '') eq 'c' ? $from_height > $needed_width : $from_height < $needed_width))) {
            $needed_width = $from_height;
        }
        # Select a source for the proportional fit, not a square thumbnail
        # based on the client's bounding box. Cropping/resize modes stay with LMS.
        my $pixels = int($needed_width);
        ++$pixels if $pixels < $needed_width;
        my $size = Slim::Web::ImageProxy->getRightSize(
            $pixels . 'x' . $pixels,
            { 320 => [320, 180], 640 => [640, 360],
              1280 => [1280, 720], 1920 => [1920, 1080] },
        ) || [1920, 1080];
        return $prefix . $size->[0] . 'x' . $size->[1] . $suffix;
    }

    return $url;
}

1;
