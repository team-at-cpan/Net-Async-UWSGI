package Net::Async::UWSGI::Server::Connection;

use strict;
use warnings;
use 5.010;
use Data::Dumper;

use parent qw(IO::Async::Stream);

use Protocol::UWSGI;
use JSON::MaybeXS;

use URI::QueryParam;
use IO::Async::Timer::Countdown;

=head1 NAME

Net::Async::UWSGI::Server::Connection - represents a client connection to a server

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 METHODS

=cut

sub protocol {
	my $self = shift;
	$self->{protocol} ||= Protocol::UWSGI->new(
	);
}

sub json { shift->{json} ||= JSON::MaybeXS->new }

sub on_read {
	my ( $self, $buffref, $eof ) = @_;
#	warn "Had " . length($$buffref) . " bytes of data\n";
	while(my $pkt = $self->protocol->extract_frame($buffref)) {
#		warn "Had UWSGI packet: " . Dumper($pkt) . "\n";
		$self->handle_packet($pkt);
	}

# $self->write( $$buffref );
#	warn "done\n";
	return 0;
}

=pod

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
	my ($self, $pkt) = @_;
	# warn "Have packet - " . Dumper($pkt);
	my $uri = $pkt->{uri};
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
				'Host: midvale',
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

Tom Molesworth <cpan@entitymodel.com>

=head1 LICENSE

Copyright Tom Molesworth 2011. Licensed under the same terms as Perl itself.

