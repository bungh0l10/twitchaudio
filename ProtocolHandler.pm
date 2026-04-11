package Plugins::Twitch::ProtocolHandler;

use strict;
use warnings;

use parent qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Log qw(logger);
use Slim::Utils::Scanner::Remote ();
use Slim::Control::Request ();

use Plugins::Twitch::API ();

my $log = logger('plugin.twitch');


sub scanUrl {
    my ($class, $uri, $args) = @_;

    return unless defined $uri && defined $args;

    my $channel = _channelFromUri($uri);
    return unless defined $channel;

    my $client = $args->{client};
    return unless defined $client;

    Plugins::Twitch::API::getChannel(
        $channel,
        sub {
            my ($data) = @_;
            return unless defined $data;

            my $user   = $data->{user}   || {};
            my $stream = $user->{stream} || {};

            my $url = Plugins::Twitch::API::getAudioUrl($channel);
            return unless defined $url;

            Slim::Utils::Scanner::Remote->scanURL($url, $args);

            my $song = $client->playingSong;
            return unless defined $song;

            my $cover = $user->{profileImageURL} || q{};

            my $meta = {
                title  => $stream->{title},
                artist => $user->{login},
                cover  => $cover,
                icon   => $cover,
                name   => q{},
            };

            $song->pluginData({ wmaMeta => $meta });

            Slim::Control::Request::notifyFromArray(
                $client,
                ['newmetadata'],
            );

            return;
        },
    );

    return;
}


sub _channelFromUri {
    my ($uri) = @_;

    return unless defined $uri;

    if ( $uri =~ m{^twitch://([^/]+)} ) {
        return lc $1;
    }

    return;
}

1;