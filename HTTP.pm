package Plugins::Twitch::HTTP;

use strict;
use warnings;
use JSON::XS qw(decode_json);
use URI;
use HTTP::Request;
use Slim::Networking::Async::HTTP;

# OAuth credentials are sent only in headers or form bodies, never in URLs.
# Do not log response bodies: token endpoints return credentials even on errors.
sub request {
    my ($method, $url, $headers, $body, $callback) = @_;
    my $complete = sub {
        my ($content, $status, $reset) = @_;
        my $data = eval { decode_json($content || '{}') };
        if ($status < 200 || $status >= 300) {
            return $callback->(undef, {
                type => 'http', status => $status,
                message => 'Twitch request failed',
                code => ref $data eq 'HASH' ? ($data->{error} || $data->{message} || '') : '',
                retry_at => $reset,
            });
        }
        return $callback->(undef, { type => 'json', message => 'Invalid Twitch response' })
            unless ref $data eq 'HASH';
        return $callback->($data);
    };
    my $request = HTTP::Request->new($method, $url);
    $request->header($_ => $headers->{$_}) for keys %$headers;
    $request->header('Accept-Encoding' => 'identity', Connection => 'close');
    $request->content($body) if defined $body;
    my $http = Plugins::Twitch::HTTP::Transport->new({});
    return $http->send_request({
        request => $request, Timeout => 15, maxRedirect => 0,
        onBody => sub {
            my $response = $_[0]->response;
            $complete->($response->content, $response->code, $response->header('Ratelimit-Reset'));
        },
        onError => sub {
            my $response = $_[0]->response;
            $complete->('', $response && $response->code >= 400 ? $response->code : 0);
        },
    });
}

sub form {
    my ($url, $params, $callback) = @_;
    my $uri = URI->new('https://localhost/');
    $uri->query_form(%$params);
    return request('POST', $url,
        { 'Content-Type' => 'application/x-www-form-urlencoded' },
        $uri->query, $callback);
}

package Plugins::Twitch::HTTP::Transport;

use parent qw(Slim::Networking::Async::HTTP);

# LMS normally disconnects as soon as it sees an HTTP 4xx/5xx header. OAuth
# needs that response body (authorization_pending / slow_down / access_denied).
# Intercept only the initial HTTP-status error; socket errors still fail normally.
sub _http_error {
    my ($self, $error, $args) = @_;
    my $response = $self->response;
    if ($response && $response->code >= 400 && !$args->{twitch_error_body}
        && $error eq $response->status_line) {
        $args->{twitch_error_body} = 1;
        $self->read_body($args);
        # Headers may already have buffered the whole body. Match LMS's normal
        # body-reading path so no extra socket event is needed in that case.
        my $socket = $self->socket;
        my $length = $response->header('Content-Length');
        Slim::Networking::Async::HTTP::_http_read_body($socket, $self, $args)
            if $socket->_rbuf_length > 0 || (defined $length && $length eq '0');
        return;
    }
    return $self->SUPER::_http_error($error, $args);
}

1;
