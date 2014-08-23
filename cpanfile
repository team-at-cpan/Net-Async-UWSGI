requires 'parent', 0;
requires 'curry', 0;
requires 'Future', '>= 0.29';
requires 'IO::Async', '>= 0.62';
requires 'Mixin::Event::Dispatch', '>= 1.006';
requires 'List::UtilsBy', 0;

on 'test' => sub {
	requires 'Test::More', '>= 0.98';
	requires 'Test::Fatal', '>= 0.010';
	requires 'Test::Refcount', '>= 0.07';
};

