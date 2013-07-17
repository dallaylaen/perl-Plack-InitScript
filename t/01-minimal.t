#!/usr/bin/perl -w

use strict;
use Test::More tests => 4;
use Test::Exception;

use Plack::InitScript;

my $plin = Plack::InitScript->new;

$plin->load_config( {} );

$plin->add_app( \*DATA );
my $app = $plin->get_app_config("1234");

is_deeply( $app, { qw( port 1234 app bar.psgi ) }, "cf loaded");

# note explain $plin;

is_deeply( $plin->get_app_config( $app->{port} ), $app, "same app via port" );

throws_ok {
	$plin->add_app( $app );
} qr(^Plack::Ini);
note $@;

throws_ok {
	$plin->add_app( {} );
} qr(^Plack::Ini);
note $@;



__DATA__
port: 1234
app: bar.psgi
