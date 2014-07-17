package Net::Async::UWSGI::Server;

use strict;
use warnings;
use 5.010;

use parent qw(IO::Async::Notifier);

use curry;
use curry::weak;

use IO::Async::Listener;
use IO::Socket::UNIX;
use Data::Dumper;

use Net::Async::UWSGI::Server::Connection;

use IO::Async::Timer::Periodic;

sub listening {
	my $self = shift;
	$self->{listening} ||= $self->loop->new_future
}

sub _add_to_loop {
	my ($self, $loop) = @_;

	my $path = "/tmp/midvale.sock";
	unlink $path if -S $path;

	my $socket = IO::Socket::UNIX->new(
		Local  => $path,
		Listen => 2048,
		Type   => SOCK_STREAM,
	) or die "Cannot make UNIX socket - $!\n";
	$socket->blocking(0) or warn "blcoking ? $!";

	my $add = $self->curry::weak::add_child;
	my $hnd = $self->curry::weak::handle_uwsgi;
	my $listener = IO::Async::Listener->new(
        on_accept => sub {
           my (undef, $socket) = @_;
#		   warn "Incoming client request\n";

		   $socket->blocking(0);# or warn "blcoking ? $!";
			my $stream = Net::Async::UWSGI::Server::Connection->new(
				handle => $socket
			);
			$add->($stream);
		},
	 );

     $self->add_child($listener);
     $listener->listen(
        handle => $socket,
     )->on_ready($self->listening)->on_done(sub {
		 $self->add_child(
		 	my $timer = IO::Async::Timer::Periodic->new(
				interval => 2,
				on_tick => $self->curry::weak::on_tick,
			)
		);
		$timer->start;
	 });
}

# IO::Async::Notifier
sub on_tick {
	my $self = shift;
	printf "%s %d children %d active connections\n", ''.localtime, 0+$self->children, 0;
}

sub handle_uwsgi {
	my $self = shift;
}

1;

