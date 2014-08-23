package Net::Async::UWSGI::Bus;

use strict;
use warnings;

use parent qw(Mixin::Event::Dispatch);

sub new { my $class = shift; bless { @_ }, $class }

1;
