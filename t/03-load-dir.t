#!/usr/bin/perl -w

use strict;
use Test::More tests => 4;
use File::Temp qw(tempdir);

use Plack::InitScript;

my $tmp = tempdir ( CLEANUP => 1 );

my $plin = Plack::InitScript->new();
mkdir ("$tmp/new") or die "Cannot create $tmp/new: $!";
mkdir ("$tmp/old") or die "Cannot create $tmp/old: $!";

$plin->load_config( { old_dir => "$tmp/old", apps_dir => "$tmp/new" } );

my $old = { app => "foo", port => 1234, old => 1, };
$plin->save_old_app( $old );
$plin->load_apps();

ok(  -r "$tmp/old/1234.yml", "File created" );

is_deeply( [$plin->get_app_config(1234)], [], "Get config = nothing" );
is_deeply( [$plin->get_app_config(1234, old => 1)], [$old], "Get config (+old)" );

$plin->rm_old_app( $old );
ok( !-r "$tmp/old/1234.yml", "File removed" );

