package Plugins::Twitch::ProtocolHandler;

use strict;
use warnings;

use parent qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Log;
use Slim::Utils::Scanner::Remote ();
use Slim::Utils::Cache;
use Slim::Control::Request ();

use Plugins::Twitch::API ();

use LWP::UserAgent;

my $log = logger('plugin.twitch');

use constant {
    PLAYBACK_CACHE_TTL => 3600,
};

my %AUDIO_PIDS = map { $_ => 1 } qw(256 257 258);

sub _set_hls_args {
    my ($args) = @_;

    @$args{qw(parser contentType streamformat noVideo)} = (
        'Plugins::PlayHLS::HLSPLAY',
        'audio/aac',
        'aac',
        1,
    );

    return;
}

sub canDirectStream { 0 }
sub isAudio          { 1 }
sub isRemote         { 1 }
sub canSeek          { 0 }
sub songBytes        { 0 }

sub scanUrl {
    my ($class, $uri, $args) = @_;

    return unless $uri && $args && $args->{client};

    my $client = $args->{client};

    if ($uri =~ m{^twitch:live:([^:]+)$}) {
        my $channel = $1;

        my $stream_url = Plugins::Twitch::API::getAudioUrl($channel);
        return unless $stream_url;

        $log->info("TWITCH LIVE STREAM URL: $stream_url");

        _set_hls_args($args);

        Slim::Utils::Scanner::Remote->scanURL($stream_url, $args);

        _applyInitialMetadata($client, "live:$channel");

        return;
    }

    if ($uri =~ m{^twitch:vod:(\d+)$}) {
        my $vod_id = $1;

        my $stream_url = Plugins::Twitch::API::getVodAudioUrl($vod_id);
        return unless $stream_url;

        $log->info("TWITCH VOD STREAM URL: $stream_url");

        _set_hls_args($args);

        Slim::Utils::Scanner::Remote->scanURL($stream_url, $args);

        # VOD metadata handled separately
        _applyInitialMetadata($client, "vod:$vod_id");

        return;
    }

    return;
}

sub _dump_m3u8_summary {
    my ($url) = @_;

    my $ua = LWP::UserAgent->new(
        timeout => 5,
        agent   => 'Mozilla/5.0',
    );

    my $res = $ua->get($url);

    unless ($res->is_success) {
        $log->warn("M3U8 fetch failed: " . $res->status_line);
        return;
    }

    my $content = $res->decoded_content;

    my ($seq, $target, $duration, $count);
    my ($first, $last);
    my $end = 0;
    my $prog;

    foreach my $l (split /\n/, $content) {

        $seq    = $1 if $l =~ /#EXT-X-MEDIA-SEQUENCE:(\d+)/;
        $target = $1 if $l =~ /#EXT-X-TARGETDURATION:(\d+)/;

        if ($l =~ /#EXTINF:([\d\.]+)/) {
            $duration = $1;
            $count++;
        }

        $first //= $l if $l =~ /^https?:\/\//;
        $last     = $l if $l =~ /^https?:\/\//;

        $end = 1 if $l =~ /#EXT-X-ENDLIST/;

        $prog = $1 if $l =~ /#EXT-X-PROGRAM-DATE-TIME:(.+)/;
    }

    $log->info("=== M3U8 SUMMARY ===");
    $log->info("Type: " . ($end ? "VOD" : "LIVE"));
    $log->info("Seq: $seq");
    $log->info("Target: $target");
    $log->info("Seg duration: $duration");
    $log->info("Segments: $count");
    $log->info("First: $first");
    $log->info("Last: $last");
    $log->info("Program time: $prog");

    return;
}

sub _probe_first_ts {
    my ($url) = @_;

    my $ua = LWP::UserAgent->new(timeout => 5);
    my $res = $ua->get($url);

    return unless $res->is_success;

    my $data = $res->content;

    return unless substr($data, 0, 1) eq "\x47";

    my %pid;

    for (my $i = 0; $i < length($data) - 188; $i += 188) {
        my $p   = ord(substr($data, $i + 1, 1));
        my $pid = (($p & 0x1F) << 8) + ord(substr($data, $i + 2, 1));
        $pid{$pid}++;
    }

    $log->info("=== TS PROBE ===");

    foreach my $k (keys %pid) {
        $log->info("PID $k => $pid{$k}");
    }

    my $audio = grep { $AUDIO_PIDS{$_} } keys %pid;

    $log->info("AUDIO DETECTED: " . ($audio ? "YES" : "NO"));
}

sub _applyInitialMetadata {
    my ($client, $id) = @_;

    return unless $client && $id;

    my $song = $client->playingSong or return;
    my $cache = Slim::Utils::Cache->new;

    if ($id =~ /^vod:(\d+)$/) {
        my $vod_id = $1;

        my $meta = $cache->get("twitch:vod:$vod_id");

        if ($meta) {
            $song->pluginData({ wmaMeta => $meta });
            Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
            return;
        }

        Plugins::Twitch::API::getVodMeta($vod_id, sub {
            my ($vod) = @_;

            return unless $vod;

            my $current = $client->playingSong or return;

            my $meta = {
                title  => $vod->{title} // 'VOD',
                artist => $vod->{artist},
                cover  => $vod->{thumbnail},
            };

            $current->pluginData({ wmaMeta => $meta });
            Slim::Control::Request::notifyFromArray($client, ['newmetadata']);

            $cache->set("twitch:vod:$vod_id", $meta, PLAYBACK_CACHE_TTL);
        });

        return;
    }

    my ($type, $channel) = split /:/, $id, 2;
    $channel ||= $id;

    my $meta = $cache->get("twitch:live:$channel");

    if ($meta) {
        $song->pluginData({ wmaMeta => $meta });
        Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
        return;
    }

    Plugins::Twitch::API::getChannel($channel, sub {
        my ($data) = @_;

        return unless $data && $data->{user};

        my $u = $data->{user};

        my $current = $client->playingSong or return;

        my $meta = {
            title  => $u->{stream}->{title} // 'Offline',
            artist => lc($u->{login}),
            cover  => $u->{profileImageURL},
        };

        $current->pluginData({ wmaMeta => $meta });
        Slim::Control::Request::notifyFromArray($client, ['newmetadata']);

        $cache->set("twitch:live:$channel", $meta, PLAYBACK_CACHE_TTL);
    });

    return;
}

1;
