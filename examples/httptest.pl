#!/usr/bin/env perl 
use strict;
use warnings;

use Net::Async::HTTP;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::Utils qw(fmap0);
use feature qw(say);

my $loop = IO::Async::Loop->new;
$loop->add(
	my $ua = Net::Async::HTTP->new(
		max_connections_per_host => 0,
		pipeline => 0,
	)
);
say "prime";
$ua->GET(
	'http://uwsgi.localhost/test'
)->get;
say "start";
my $total = 0; my $active = 0;
$loop->add(IO::Async::Timer::Periodic->new(
	interval => 1,
	reschedule => 'skip',
	on_tick => sub {
		printf "%d total, %d active\n", $total, $active;
	}
)->start);
(fmap0 {
	++$active;
	$ua->GET(
		'http://uwsgi.localhost/test'
	)->on_ready(sub { --$active; ++$total })
} concurrent => 256, generate => sub { 1 })->get;

#IO::Async::ChildManager
