#!/usr/bin/env perl 
use strict;
use warnings;
use 5.010;
use IO::Async::Loop::Epoll;
use Net::Async::UWSGI::Server;
my $loop = IO::Async::Loop::Epoll->new;
my $srv = Net::Async::UWSGI::Server->new;
$loop->add($srv);
$loop->run;

