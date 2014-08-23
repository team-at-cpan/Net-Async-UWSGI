package Net::Async::UWSGI::Server;

use strict;
use warnings;

use parent qw(IO::Async::Notifier);

use curry;
use curry::weak;

use IO::Async::Listener;

use Mixin::Event::Dispatch::Bus;
use Net::Async::UWSGI::Server::Connection;

use Scalar::Util qw(weaken);
use URI;
use URI::QueryParam;
use JSON::MaybeXS;
use Encode qw(encode);
use Future;
use HTTP::Response;

use Protocol::UWSGI qw(:server);

sub path { shift->{path} }
sub backlog { shift->{backlog} }
sub mode { shift->{mode} }

sub configure {
	my ($self, %args) = @_;
	for(qw(path backlog mode on_request)) {
		$self->{$_} = delete $args{$_} if exists $args{$_};
	}
	$self->SUPER::configure(%args);
}

sub _add_to_loop {
	my ($self, $loop) = @_;
	delete $self->{listening};
	$self->listening;
	()
}

sub listening {
	my ($self) = @_;
	return $self->{listening} if exists $self->{listening};

	defined(my $path = $self->path) or die "No path provided";
	unlink $path or die "Unable to remove existing $path socket - $!" if -S $path;

	my $f = $self->loop->new_future->set_label('listener startup');
	$self->{listening} = $f;
	my $listener = IO::Async::Listener->new(
		on_accept => $self->curry::incoming_socket,
	);

	$self->add_child($listener);
	$listener->listen(
		addr => {
			family      => 'unix',
			socktype    => 'stream',
			path        => $self->path,
		},

		on_listen => $self->curry::on_listen_start($f),
		# on_stream => $self->curry::incoming_stream,

		on_listen_error => sub {
			$f->fail(listen => "Cannot listen - $_[1]\n");
		},
	);
	$f
}

sub on_listen_start {
	my ($self, $f, $listener) = @_;

	my $sock = $listener->read_handle;

	# Make sure the socket is accessible
	if(my $mode = $self->mode) {
		# Allow octal-as-string
		$mode = oct $mode if substr($mode, 0, 1) eq '0';
		$self->debug_printf("chmod %s to %04o", $self->path, $mode);
		chmod $mode, $self->path or $f->fail(listen => 'unable to chmod socket - ' . $!);
	}

	# Support custom backlog (default 1 is usually too low)
	if(my $backlog = $self->backlog) {
		$self->debug_printf("Set listen queue on %s to %d", $self->path, $backlog);
		$sock->listen($backlog) or die $!;
	}

	$f->done($listener);
}

=head2 incoming_socket

Called when we have an incoming socket. Usually indicates a new request.

=cut

sub incoming_socket {
	my ($self, $listener, $socket) = @_;
	$self->debug_printf("Incoming socket - %s, total now ", $socket, 0+$self->children);

	$socket->blocking(0);
	my $stream = Net::Async::UWSGI::Server::Connection->new(
		handle     => $socket,
		bus        => $self->bus,
		on_request => $self->{on_request},
		autoflush  => 1,
	);
	$self->add_child($stream);
}

=head2 bus

The event bus. See L<Mixin::Event::Dispatch::Bus>.

=cut

sub bus { shift->{bus} ||= Mixin::Event::Dispatch::Bus->new }

sub incoming_stream {
	my ($self, $stream) = @_;
	$self->debug_printf("Configuring stream $stream");
	my $response = $self->loop->new_future;
	my $start = $self->timeout('http_request_headers');

	# Clean up everything when the response is done
	$response->on_ready(sub {
		$stream->want_writeready(0);
		$stream->want_readready(0);
		$stream->close_now;
		undef $stream;
		weaken($response);
	});

	$stream->configure(
		on_read_error => sub {
			my ($self, @stuff) = @_;
			ERROR("on_read_error @_");
			$response->cancel unless $response->is_ready;
		},
		on_write_error => sub {
			my ($self, @stuff) = @_;
			ERROR("on_write_error @_");
			$response->cancel unless $response->is_ready;
		},
		on_read => $self->curry::weak::on_read($response),
	);
	$self->add_child($stream);
}

sub on_read {
	my ($self, $response, $stream, $buffref, $eof) = @_;
	warn "br = $buffref\n";
	if(my $frame = extract_frame($buffref)) {
		my $uri = uri_from_env($frame);
		warn "Had UWSGI frame for " . $uri . "\n";
		my $k = "$response";
		$self->{requests}{$k} = my $f = $self->dispatch_request(
			$frame,
		)->else(sub {
			$self->debug_printf("Failure, passing through error: @_");
			# Pass through errors, but give us a chance to log the stat
			return Future->wrap(@_)
		})->then(sub {
			my ($code, $body) = @_;
			$self->debug_printf("Had $code and $body");
			$self->stats('response.code' => $code);
			$self->write_response(
				$stream,
				$code => $body
			)
		})->on_ready(sub {
			$self->debug_printf("Wrote response");
			$response->done;
			# Clean up when we're done
			delete $self->{requests}{$k}
		});

		# If the client cancels, so should we
		$response->on_ready(sub {
			$f->cancel unless $f->is_ready
		});
	}
	if($eof) {
		$response->cancel unless $response->is_ready;
	}
	return 0;
}
{
my %status = (
	200 => 'OK',
	204 => 'No content',
	400 => 'Bad request',
	404 => 'Not found',
	500 => 'Internal server error',
);
sub write_response {
	my ($self, $stream, $code, $body) = @_;
	my $content = ref($body)
		? encode_json($body)
		: encode('UTF-8' => $body);
	$stream->write(
		'HTTP/1.1 ' . HTTP::Response->new(
			$code => ($status{$code} // 'Unknown'), [
				'Content-Type'   => 'application/javascript',
				'Content-Length' => length $content,
				'Connection'     => 'close',
			],
			$content
		)->as_string("\x0D\x0A")
	)
}
}

sub dispatch_request {
	my ($self, $req) = @_;
	$self->debug_printf("Handling request for [" . $req->{uri} . "]");
	Future->wrap(
		200 => { status => 'success' }
	)
}

1;

