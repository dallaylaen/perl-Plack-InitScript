#!/usr/bin/perl -w

use strict;

alarm 60;

my $app = sub {
	return [ 200, ["Content-Type" => "text/plain"], ["Oll Korrect\n"]];
};
