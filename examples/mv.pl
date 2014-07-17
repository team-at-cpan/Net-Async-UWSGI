#!/usr/bin/env perl 
use strict;
use warnings;
sub uwsgi(@) {
	my %args = @_;
	my $srv = Net::Async::UWSGI::Server->new;
	$myr->add_child($srv);
}

sub site(&;@) {
	my ($code, %args) = @_;

}

sub request {
	my ($base, $code) = @_;

}

uwsgi
	path => '/tmp/uwsgi.sock',
	listen_queue => 8192;

my $url_version = '/(\d+\.\d+\.\d+)';

site {
	request $url_version . '/context' => sub {
		my ($req) = @_;
		return $mv->context(
			app => $req->application,
			user => $req->user,
		);
	}, content_type => 'json';
	request $url_version . '/register' => sub {
		my ($req) = @_;
		return $mv->register(
		);
	}, content_type => 'json';
	request $url_version . '/listener' => sub {
		my ($req) = @_;
		return $mv->listen(
		);
	}, content_type => 'json';
};

sub context {
	my ($self, %args) = @_;
	Future->wrap({
		context => '...'
	})
}

sub register {
	my ($self, %args) = @_;
	$self->prepare(
		%args
	)
}

sub listen : method {
	my ($self, %args) = @_;
	$self->prepare(
		%args
	)->then(sub {
		$self->acquire_channel
	})->then(sub {
		$ch->start_consumer($q)
	})->then(sub {
		$ch->start_consumer($q)
	})
}

	$site->register_path($url_version . '/context' => sub {
		my ($req) = @_;
		return $mv->context(
			app => $req->application,
			user => $req->user,
		);
	}, content_type => 'json');

	request $url_version . '/register' => sub {
		my ($req) = @_;
		return $mv->register(
		);
	}, content_type => 'json';
	request $url_version . '/listener' => sub {
		my ($req) = @_;
		return $mv->listen(
		);
	}, content_type => 'json';
	);
