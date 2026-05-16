package Plugins::Twitch::ProtocolHandler;

use strict;
use warnings;

use base qw(IO::Handle);

use List::Util qw(min);
use parent qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Log;
use Slim::Utils::Scanner::Remote ();
use Slim::Utils::Cache;
use Slim::Control::Request ();
use Slim::Networking::Async::HTTP;
use Slim::Networking::SimpleAsyncHTTP;

use Plugins::Twitch::API ();

use Plugins::Twitch::M4A;
use Plugins::Twitch::MPEGTS;
use Plugins::Twitch::HTTP;

use constant {
    LIVE_CACHE_TTL => 60,
    VOD_CACHE_TTL  => 86400,

    MIN_OUT   => 8192,
    DATA_CHUNK => 128 * 1024,
};

my $log   = logger('plugin.twitch.protocol');
my $cache = Slim::Utils::Cache->new('Twitch');

# ------------------------------------------------------------
# CAPABILITIES
# ------------------------------------------------------------
sub canDirectStream { 0 }
sub isAudio         { 1 }
sub isRemote        { 1 }
sub canSeek         { 0 }
sub songBytes       { 0 }

# ------------------------------------------------------------
# NEW
# ------------------------------------------------------------
sub new {
    my ($class, $args) = @_;

    my $song   = $args->{song};
    my $config = $song->pluginData('config');

    return unless $config;

    my $self = $class->SUPER::new;

    my $vars = {
        outBuf    => '',
        streaming => 1,
        fetching  => 0,
        retry     => 5,
        offset    => 0,
        sessions  => [],
    };

    ${*$self}{client} = $args->{client};
    ${*$self}{song}   = $song;
    ${*$self}{config} = $config;
    ${*$self}{vars}   = $vars;
    ${*$self}{stash}  = $song->pluginData('stash') || {};

    return $self;
}

# ------------------------------------------------------------
# CLOSE
# ------------------------------------------------------------
sub close {
    my $self = shift;

    if (my $sessions = ${*$self}{vars}->{sessions}) {
        $_->disconnect foreach @$sessions;
    }

    $self->SUPER::close(@_);
}

# ------------------------------------------------------------
# SYSREAD ENTRY
# ------------------------------------------------------------
sub sysread {
    my $self = $_[0];

    my $vars   = ${*$self}{vars};
    my $config = ${*$self}{config};

    return $config->{sysread}->($self, $vars, $config, @_);
}

# ------------------------------------------------------------
# HTTP BYTE STREAM (M4A)
# ------------------------------------------------------------
sub sysread_URL {
    use bytes;

    my ($self, $v, $config) = splice(@_, 0, 3);

    my $handler = $config->{handler};

    if (
        length($v->{outBuf}) < MIN_OUT
        && !$v->{fetching}
        && $v->{streaming}
    ) {

        my $url = $config->{url};

        my $session = $v->{sessions}->[0]
            ||= Slim::Networking::Async::HTTP->new;

        my $request = HTTP::Request->new(
            GET => $url,
            [
                'Connection' => 'keep-alive',
                'Range'      => "bytes=$v->{offset}-"
                    . ($v->{offset} + DATA_CHUNK - 1),
            ]
        );

        $request->protocol('HTTP/1.1');

        $v->{fetching} = 1;

        $session->send_request({

            request => $request,

            onBody => sub {
                my $response = shift->response;

                $handler->addBytes($response->content_ref);

                my $len = length $response->content;

                $v->{offset} += $len;
                $v->{fetching} = 0;
                $v->{retry}    = 5;

                $v->{streaming} = 0
                    if $len < DATA_CHUNK;

                $log->debug("received m4a chunk: $len");
            },

            onError => sub {
                $v->{retry}--;
                $v->{fetching} = 0;

                $log->error("m4a fetch error");
            },
        });
    }

    $handler->getAudio(\$v->{outBuf})
        if $handler->bufferLength;

    if (my $bytes = min(length($v->{outBuf}), $_[2])) {

        $_[1] = substr($v->{outBuf}, 0, $bytes, '');

        return $bytes;
    }
    elsif ($v->{streaming} && $v->{retry} > 0) {

        $! = EINTR;
        return undef;
    }

    return 0;
}

# ------------------------------------------------------------
# HLS MPEGTS
# ------------------------------------------------------------
sub sysread_HLS_MPEG {
    use bytes;

    my ($self, $v, $config) = splice(@_, 0, 3);

    my $mpeg    = ${*$self}{stash};
    my $handler = $config->{handler};

    my $fragments = $mpeg->{fragments};

    if (
        length($v->{outBuf}) < MIN_OUT
        && !$v->{fetching}
        && $v->{streaming}
    ) {

        my $url = $fragments->[$v->{offset}];

        unless ($url) {
            $v->{streaming} = 0;
            goto AUDIO;
        }

        $v->{fetching} = 1;

        $self->sendRequest(
            $url,
            0,

            sub {
                my $response = shift->response;

                $handler->addBytes($response->content_ref);

                $v->{offset}++;
                $v->{fetching} = 0;
                $v->{retry}    = 5;

                $log->debug("received ts fragment");
            },

            sub {
                $v->{fetching} = 0;
                $v->{retry}--;

                $log->error("fragment fetch failed");
            },
        );
    }

AUDIO:

    $handler->getAudio(\$v->{outBuf})
        if $handler->bufferLength;

    if (my $bytes = min(length($v->{outBuf}), $_[2])) {

        $_[1] = substr($v->{outBuf}, 0, $bytes, '');

        return $bytes;
    }
    elsif ($v->{streaming}) {

        $! = EINTR;
        return undef;
    }

    return 0;
}

# ------------------------------------------------------------
# SEND REQUEST
# ------------------------------------------------------------
sub sendRequest {
    my ($self, $url, $level, $onBody, $onError) = @_;

    my $v = ${*$self}{vars};

    my $request = HTTP::Request->new(
        GET => $url,
        ['Connection' => 'keep-alive']
    );

    $request->protocol('HTTP/1.1');

    my $session = $v->{sessions}->[$level];

    unless ($session) {
        $session = $v->{sessions}->[$level]
            = Plugins::Twitch::HTTP->new;
    }

    $session->send_request({

        request => $request,

        onRedirect => sub {
            my $redir = shift->uri;

            $self->sendRequest(
                $redir,
                $level + 1,
                $onBody,
                $onError
            );
        },

        onBody => sub {
            $onBody->(@_);
        },

        onError => sub {
            $onError->(@_);
        },
    });
}

# ------------------------------------------------------------
# HLS PLAYLIST PARSER
# ------------------------------------------------------------
sub getHLSFragments {
    my ($url, $cb) = @_;

    Slim::Networking::SimpleAsyncHTTP->new(

        sub {
            my $m3u8 = shift->content;

            my @fragments;

            for my $item (split(/#EXTINF/, $m3u8)) {

                next unless $item =~ /[^\n]*\n(\S+\.ts.*)$/m;

                push @fragments, $1;
            }

            my ($base) = $url =~ m|(^https://[^/]+/)|;

            @fragments = map {
                /^https/
                    ? $_
                    : $base . $_
            } @fragments;

            $cb->({
                fragments => \@fragments,
            });
        },

        sub {
            $log->error("cannot load hls playlist");
            $cb->();
        },

    )->get($url);
}

# ------------------------------------------------------------
# ENTRY POINT
# ------------------------------------------------------------
sub scanUrl {
    my (undef, $uri, $args) = @_;

    return unless $uri && $args && $args->{client};

    my $client = $args->{client};

    if (my ($channel) = $uri =~ /^twitch:live:([^:]+)$/) {
        return _handleLive($client, $channel, $args);
    }

    if (my ($vod_id) = $uri =~ /^twitch:vod:(\d+)$/) {
        return _handleVod($client, $vod_id, $args);
    }

    return;
}

# ------------------------------------------------------------
# LIVE HANDLER
# ------------------------------------------------------------
sub _handleLive {
    my ($client, $channel, $args) = @_;

    my $stream_url = Plugins::Twitch::API::getAudioUrl($channel)
        or return;

    $log->info("LIVE STREAM URL: $stream_url");

    return _initStream(
        $client,
        $stream_url,
        $args,
        "live:$channel"
    );
}

# ------------------------------------------------------------
# VOD HANDLER
# ------------------------------------------------------------
sub _handleVod {
    my ($client, $vod_id, $args) = @_;

    my $stream_url = Plugins::Twitch::API::getVodAudioUrl($vod_id)
        or return;

    $log->info("VOD STREAM URL: $stream_url");

    return _initStream(
        $client,
        $stream_url,
        $args,
        "vod:$vod_id"
    );
}

# ------------------------------------------------------------
# STREAM INIT
# ------------------------------------------------------------
sub _initStream {
    my ($client, $url, $args, $meta_id) = @_;

    my $song = $args->{song};

    if ($url =~ /\.m3u8/i) {

        getHLSFragments($url, sub {

            my $data = shift or return;

            my $handler = Plugins::Twitch::MPEGTS->new($url);

            my $config = {
                url      => $url,
                source   => 'hls-mpeg',
                format   => 'aac',
                handler  => $handler,
                sysread  => \&sysread_HLS_MPEG,
            };

            $song->pluginData(config => $config);
            $song->pluginData(stash  => $data);

            $handler->initialize(
                sub {
                    _applyInitialMetadata($client, $meta_id);
                },
                sub {
                    $log->error("mpegts init failed");
                },
                $data->{fragments}->[0],
            );
        });

    }
    else {

        my $handler = Plugins::Twitch::M4A->new($url);

        my $config = {
            url      => $url,
            source   => 'm4a',
            format   => 'aac',
            handler  => $handler,
            sysread  => \&sysread_URL,
        };

        $song->pluginData(config => $config);

        $handler->initialize(
            sub {
                _applyInitialMetadata($client, $meta_id);
            },
            sub {
                $log->error("m4a init failed");
            }
        );
    }

    return;
}

# ------------------------------------------------------------
# METADATA ENTRY
# ------------------------------------------------------------
sub _applyInitialMetadata {
    my ($client, $id) = @_;

    return unless $client && $id;

    my $song = $client->playingSong or return;

    if (my ($vod_id) = $id =~ /^vod:(\d+)$/) {
        return _applyVodMetadata($client, $song, $vod_id);
    }

    if (my ($channel) = $id =~ /^live:(.+)$/) {
        return _applyLiveMetadata($client, $song, $channel);
    }

    return;
}

# ------------------------------------------------------------
# VOD METADATA
# ------------------------------------------------------------
sub _applyVodMetadata {
    my ($client, $song, $vod_id) = @_;

    my $cache_key = "plugin:twitch:vod:$vod_id";

    if (my $cached = $cache->get($cache_key)) {
        return _restoreMeta($client, $song, $cached);
    }

    Plugins::Twitch::API::getVodMeta($vod_id, sub {
        my ($vod) = @_;

        return unless $vod;

        my $fresh = {
            artist => ($vod->{artist} // ''),
            cover  => ($vod->{thumbnail} // ''),
            title  => ($vod->{title} // 'VOD'),
        };

        _updateIfChanged(
            $client,
            $song,
            $fresh,
            $cache,
            $cache_key,
            VOD_CACHE_TTL
        );
    });

    return;
}

# ------------------------------------------------------------
# LIVE METADATA
# ------------------------------------------------------------
sub _applyLiveMetadata {
    my ($client, $song, $channel) = @_;

    my $cache_key = "plugin:twitch:live:$channel";

    if (my $cached = $cache->get($cache_key)) {
        _restoreMeta($client, $song, $cached);
    }

    Plugins::Twitch::API::getChannel($channel, sub {
        my ($data) = @_;

        return unless $data && $data->{user};

        my $u = $data->{user};

        my $fresh = {
            artist => lc($u->{login} // ''),
            cover  => ($u->{profileImageURL} // ''),
            title  => (
                    $u->{stream}
                &&  $u->{stream}->{title}
            )
                ? $u->{stream}->{title}
                : 'Offline',
        };

        _updateIfChanged(
            $client,
            $song,
            $fresh,
            $cache,
            $cache_key,
            LIVE_CACHE_TTL
        );
    });

    return;
}

# ------------------------------------------------------------
# UPDATE HELPERS
# ------------------------------------------------------------
sub _updateIfChanged {
    my ($client, $song, $fresh, $cache_obj, $key, $ttl) = @_;

    my $old = $song->pluginData('wmaMeta') || {};

    return unless _metadataChanged($old, $fresh);

    my $current = $client->playingSong or return;

    return unless $current == $song;

    $song->pluginData({ wmaMeta => $fresh });

    Slim::Control::Request::notifyFromArray(
        $client,
        ['newmetadata']
    );

    $cache_obj->set($key, $fresh, $ttl);

    return;
}

sub _restoreMeta {
    my ($client, $song, $cached) = @_;

    return unless $cached;

    my $current = $client->playingSong or return;

    return unless $current == $song;

    my $old = $song->pluginData('wmaMeta') || {};

    return unless _metadataChanged($old, $cached);

    $song->pluginData({ wmaMeta => $cached });

    Slim::Control::Request::notifyFromArray(
        $client,
        ['newmetadata']
    );

    return;
}

sub _metadataChanged {
    my ($old, $new) = @_;

    $old ||= {};
    $new ||= {};

    return 1
        if ($old->{title} // '') ne ($new->{title} // '');

    return 1
        if ($old->{artist} // '') ne ($new->{artist} // '');

    return 1
        if ($old->{cover} // '') ne ($new->{cover} // '');

    return 0;
}

1;