#!/usr/bin/perl -w

use strict;
use Test::More tests => 10;
use IO::Socket::INET;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use LWP::UserAgent;
use English;

use Plack::InitScript;

my $dir = tempdir( CLEANUP => !$ENV{TEST_DIR_PRESERVE} );
END {
	if ($ENV{TEST_DIR_PRESERVE}) {
		diag " !!! TEST DIR = $dir";
	};
};
my $port = find_port();
my $uri = "http://localhost:$port/";
my $ag = LWP::UserAgent->new ( timeout => 1 );

$SIG{ALRM} = sub { diag "Script timed out"; die "Script timed out"; };
alarm 10;

$SIG{__DIE__} = \&Carp::confess;

my ($user)  = getpwuid ( $UID );
my ($group) = getgrgid ( $GID );

my $plin = Plack::InitScript->new;
$plin->set_defaults( pid_file => "$dir/pid.%p", server => 'plackup',
	log_file => "$dir/log", user => $user, group => $group, );

$plin->add_app({ name => 'foo', port => $port, app => "$Bin/psgi/die-soon.psgi" });

my $app = $plin->get_app_config( $port );
note "App = ", explain $app;
note "Init options = ", explain $plin->get_init_options( $app );

my $stat = $plin->service( "start", "foo" );
ok (-f "$dir/pid.$port", "pidfile created"); # TODO check content!
is_deeply ([ keys %$stat ], [ $port ], "return from service: port=>1");
ok ( $stat->{$port}, "pid set ($stat->{$port})" );

sleep 1; # TODO replace with logfile content check
my $resp = $ag->get( $uri );
ok ($resp->is_success, "request ok!")
	or diag explain $resp;

$stat = $plin->service( "status", "foo" );
is_deeply ([ keys %$stat ], [ $port ], "return from service: port=>1");
ok ( $stat->{$port}, "pid set ($stat->{$port})" );

$stat = $plin->service( "stop", "foo", $port, "foo" ); # stops once!
is_deeply ($stat, { $port => 0 }, "return from service: port=>0");

$stat = $plin->service( "status", "foo" );
is_deeply ($stat, { $port => 0 }, "return from service: port=>0");

$resp = $ag->get( $uri );
ok (!$resp->is_success, "request not ok!")
	or diag explain $resp;
like ($resp->status_line, qr(timed? ?out|nection refused)i, "Error as expected");

# system "cat", "$dir/log";

###########################
# Utility

sub find_port {
	for (1..100) {
		my $port = 1024 + int ( rand() * 60000 );
		my $sock = IO::Socket::INET->new(
			Proto => 'tcp',
			Listen => 5,
			LocalPort => $port,
			LocalAddr => 'localhost',
		);
		# note "$sock, $port, $!";
		$sock or next;
		close $sock;
		note "Found port: $port";
		return $port;
	};
	die "Cannot find empty port";
};
