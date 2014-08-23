package Net::Async::UWSGI::Server::Connection;

use strict;
use warnings;

use parent qw(IO::Async::Stream Protocol::UWSGI);

=head1 NAME

Net::Async::UWSGI::Server::Connection - represents an incoming connection to a server

=head1 SYNOPSIS

=head1 DESCRIPTION

=cut

use JSON::MaybeXS;

use URI::QueryParam;
use IO::Async::Timer::Countdown;

use Encode qw(encode);
use Protocol::UWSGI qw(:server);
use List::UtilsBy qw(bundle_by);

=head2 CONTENT_TYPE_HANDLER

=cut

our %CONTENT_TYPE_HANDLER = (
	'application/javascript' => 'json',
);

=head1 METHODS

=cut

=head2 configure

Applies configuration parameters.

=over 4

=item * bus - the event bus

=item * on_request - callback when we get an incoming request

=back

=cut

sub configure {
	my ($self, %args) = @_;
	for(qw(bus on_request default_content_handler)) {
		$self->{$_} = delete $args{$_} if exists $args{$_};
	}
	$self->SUPER::configure(%args);
}

sub default_content_handler { shift->{default_content_handler} }

=head2 json

Accessor for the current JSON state

=cut

sub json { shift->{json} ||= JSON::MaybeXS->new(utf8 => 1) }

=head2 on_read

Base read handler for incoming traffic.

Attempts to delegate to L</dispatch_request> as soon as we get the UWSGI
frame.

=cut

sub on_read {
	my ( $self, $buffref, $eof ) = @_;
	if(my $pkt = extract_frame($buffref)) {
		$self->{env} = $pkt;
		# We have a request, start processing
		return $self->dispatch_request;
	} elsif($eof) {
		# EOF before a valid request? Bail out immediately
		$self->cancel;
	}
	return 0;
}

=head2 cancel

Cancels any request in progress.

If there's still a connection to the client,
they'll receive a 500 response.

It's far more likely that the client has gone
away, in which case there's no response to send.

=cut

sub cancel {
	my ($self) = @_;
	$self->response->cancel unless $self->response->is_ready
}

=head2 env

Accessor for the UWSGI environment.

=cut

sub env { shift->{env} }

=head2 response

Resolves when the response is complete.

=cut

sub response {
	$_[0]->{response} ||= $_[0]->loop->new_future;
}

=head2 dispatch_request

At this point we have a request including headers,
and we should know whether there's a body involved
somewhere.

=cut

sub dispatch_request {
	my ($self) = @_;
#	my $uri = uri_from_env(my $env = $self->env);
#	$self->debug_printf("Handling %s request for [%s]", $env->{REQUEST_METHOD}, $uri);
#	$self->debug_printf("Key [%s] is %s", $_, $env->{$_}) for sort keys %$env;

	# Plain GET request? We might be able to bail out here
	return $self->finish_request unless $self->has_body;

	# We're using the JSON filter here. Hardcoded.
	$self->{input_handler} = $self->curry::weak::json_handler;

	# Okay, still something left... try to read N bytes if we have content length
	my $env = $self->env;
	$self->{remaining} = $env->{CONTENT_LENGTH};
	return $self->can('read_to_length') if $env->{CONTENT_LENGTH};

	# Streaming would be nice, but nginx has no support for this
	if(exists $env->{HTTP_TRANSFER_ENCODING} && $env->{HTTP_TRANSFER_ENCODING} eq 'chunked') {
		return $self->can('read_chunked');
	}
	die "no idea how to handle this, missing length and not chunked";
}

sub finish_request {
	my ($self) = @_;
	$self->{request_body} = $self->json->incr_parse
		if $self->has_body;
	$self->{completion} = $self->{on_request}->($self)
	 ->then($self->curry::write_response)
	 ->on_fail(sub { warn "failed? @_" })
	 ->on_ready($self->curry::close_now);
	0
}

{
my %methods_with_body = (
	PUT  => 1,
	POST => 1,
);

=head2 has_body

Returns true if we're expecting a request body
for the current request method.

=cut

sub has_body {
	my ($self, $env) = @_;
	return 1 if $methods_with_body{$self->env->{REQUEST_METHOD}};
	return 0;
}
}

=head2 read_chunked

Read handler for chunked data.

=cut

sub read_chunked {
	my ($self, $buffref, $eof) = @_;
	$self->debug_printf("Body read: $self, $buffref, $eof: [%s]", $$buffref);
	if(defined $self->{chunk_remaining}) {
		my $data = substr $$buffref, 0, $self->{chunk_remaining}, '';
		$self->{chunk_remaining} -= length $data;
		$self->debug_printf("Had %d bytes, %d left in chunk", length($data), $self->{chunk_remaining});
		$self->{input_handler}->($data);
		return 0 if $self->{chunk_remaining};
		$self->debug_printf("Look for next chunk");
		delete $self->{chunk_remaining};
		return 1;
	} else {
		return 0 if -1 == (my $size_len = index($$buffref, "\x0D\x0A"));
		$self->{chunk_remaining} = hex substr $$buffref, 0, $size_len, '';
		substr $$buffref, 0, 2, '';
		$self->debug_printf("Have %d bytes in this chunk", $self->{chunk_remaining});
		return 1 if $self->{chunk_remaining};
		$self->debug_printf("End of chunked data, looking for trailing headers");
		return $self->can('on_trailing_header');
	}
}

=head2 on_trailing_header

Deal with trailing headers.

=cut

sub on_trailing_header {
	my ($self, $buffref, $eof) = @_;
	# FIXME not yet implemented
	$$buffref = '';
	return $self->finish_request;
}

=head2 read_to_length

Read up to the expected fixed length of data.

=cut

sub read_to_length {
	my ($self, $buffref, $eof) = @_;
	$self->{remaining} -= length $$buffref;
	$self->debug_printf("Body read: $self, $buffref, $eof: %s with %d remaining", $$buffref, $self->{remaining});
	$self->{input_handler}->($$buffref);
	$$buffref = '';
	return $self->finish_request unless $self->{remaining};
	return 0;
}

sub json_handler {
	my ($self, $data) = @_;
	$self->json->incr_parse($data);
}

my %status = (
	200 => 'OK',
	204 => 'No content',
	400 => 'Bad request',
	404 => 'Not found',
	500 => 'Internal server error',
);
use constant USE_HTTP_RESPONSE => 0;
sub write_response {
	my ($self, $code, $hdr, $body) = @_;
	my $content = ref($body) ? encode_json($body) : encode(
		'UTF-8' => $body
	);
	$hdr ||= [];
	if(USE_HTTP_RESPONSE) {
		return $self->write(
			'HTTP/1.1 ' . HTTP::Response->new(
				$code => ($status{$code} // 'Unknown'), [
					'Content-Type' => 'application/javascript',
					'Content-Length' => length $content,
					@$hdr
				],
				$content
			)->as_string("\x0D\x0A")
		)
	} else {
		return $self->write(
			join "\015\012", (
				'HTTP/1.1 ' . $code . ' ' . ($status{$code} // 'Unknown'),
				'Content-Type: application/javascript',
				'Content-Length: ' . length($content),
				'',
				$content
			)
		)
	}
}

=pod

Requests with no body:
* GET
* HEAD
* OPTIONS
* DELETE

Expect a body:
* POST
* PUT

JSON handler:

http://tools.ietf.org/html/rfc7230#section-3.3

 Presence of a message body is signalled by a Content-Length
 or Transfer-Encoding header.

Have Content-Length:
* Read N bytes, via ->incr_parse, process completion
Have T-E: Chunked:
* Read length/data pieces, ->incr_parse, completion


'env' => {
'HTTP_ACCEPT_LANGUAGE' => 'en-GB,en-US;q=0.8,en;q=0.6',
'REMOTE_PORT' => '57574',
'PATH_INFO' => '/1.6.0/test',
'HTTP_HOST' => 'midvale.lewisham.rumah',
'HTTP_CONNECTION' => 'keep-alive',
'QUERY_STRING' => '',
'HTTP_ACCEPT' => 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
'CONTENT_TYPE' => '',
'REQUEST_METHOD' => 'GET',
'SERVER_NAME' => 'midvale.lewisham.rumah',
'SERVER_PROTOCOL' => 'HTTP/1.1',
'HTTP_ACCEPT_ENCODING' => 'gzip,deflate,sdch',
'REQUEST_URI' => '/1.6.0/test',
'REMOTE_ADDR' => '192.168.1.1',
'HTTP_CACHE_CONTROL' => 'max-age=0',
'HTTP_USER_AGENT' => 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/35.0.1916.153 Safari/537.36',
'SERVER_PORT' => '80',
'CONTENT_LENGTH' => '',
'UWSGI_SCHEME' => 'http',
'DOCUMENT_ROOT' => '/home/tom/dev/TrendMicro/midvale1.6'
},
=cut

sub handle_packet {
	my ($self, $env) = @_;
	# warn "Have packet - " . Dumper($pkt);
	my $uri = uri_from_env($env);
	my $q = $uri->query_form_hash;
	my %param;
	for my $k (keys %$q) {
		$param{$k} = [
			map split(/[, ]/, $_),	# list separation characters
				ref($q->{$k})		# expand arrayrefs
				? @{$q->{$k}}
				: ($q->{$k})
		];
	}
	# IO::Async::Timer::Countdown
	my $write = $self->curry::weak::write;
	my $timer = IO::Async::Timer::Countdown->new(
		delay => 0.3,
		remove_on_expire => 1,
        on_expire => sub {
			my $raw = Encode::encode('UTF-8' => $self->json->encode({ some_data => 123 }));
			my @http = (
				'HTTP/1.1 200 OK',
				'Host: localhost',
				'Content-Type: application/javascript',
				'Content-Length: ' . length($raw),
				'',
				$raw
			);
		#	say for @http;
			$write->(
				join "\015\012", @http
			)->on_done(
				$self->curry::weak::close
			);
        },
	);

	$timer->start;

	$self->add_child( $timer );
	# immediately starts the response and stream the content
	return sub {
		my $responder = shift;
		my $writer = $responder->([
			200, [
				'Content-Type', 'application/json'
			]
		]);

		wait_for_events(sub {
			my $new_event = shift;
			if ($new_event) {
				$writer->write($new_event->as_json . "\n");
			} else {
				$writer->close;
			}
		});
	};
}

1;

__END__

=head1 SEE ALSO

=head1 AUTHOR

Tom Molesworth <cpan@perlsite.co.uk>

=head1 LICENSE

Copyright Tom Molesworth 2011-2014. Licensed under the same terms as Perl itself.

