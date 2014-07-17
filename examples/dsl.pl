#!/usr/bin/env perl 
use strict;
use warnings;

sub http { }
sub uwsgi { }
sub spdy { }

package main;

http {
	port 80;
	port 443 => {
		ssl => 1
	};
};
spdy {
	port 443 => {
		ssl => 1,
		protocol => ['spdy/3']
	};
} '';
uwsgi {
	path '/tmp/uwsgi.sock';
};

site {
	host 'perlsite.co.uk';
	location '/' => sub {

	};
};
