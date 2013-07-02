use 5.006;
use strict;
use warnings FATAL => 'all';

package Plack::InitScript;

=head1 NAME

Plack::InitScript - Manage multiple PSGI applications with one sys V init script.

=head1 VERSION

Version 0.01

=cut

our $VERSION = 0.0104;

=head1 SYNOPSIS

    sudo service plack restart foo

=head1 METHODS

=cut

use Carp;
use Daemon::Control;

# use YAML::XS; # TODO eval require, fall back to YAML
use YAML qw(LoadFile);

use fields qw(config apps ports defaults);
our @SERVICE_FIELDS = qw( name port app format pidfile logfile server );
my %SERVICE_FIELDS;
@SERVICE_FIELDS{@SERVICE_FIELDS} = @SERVICE_FIELDS; # make hash for search

=head2 new

=cut

sub new {
	my $class = shift;
	my %opt = @_; # TODO unused
	my $self = fields::new($class);

	$self->clear_apps;
	return $self;
};

=head2 load_config

=cut

sub load_config {
	my $self = shift;
	my $config = shift;

	$config = $self->_load_cf($config);

	# TODO check config for consistency

	$self->{config} = { %$config }; # shallow copy

	my $def = delete $self->{config}{defaults};
	$def and $self->set_defaults( %$def );

	return $self;
};

=head2 set_defaults ( %hash )

Set up default values (pid_file, etc) for services.

=cut

sub set_defaults {
	my $self = shift;
	my %def = @_;

	my $olddef = $self->{defaults} || {};
	$self->{defaults} = { %$olddef, %def };

	# TODO fail if $pid_file !~ %p || %n

	return $self;
};

=head2 load_apps

Load all apps based on config

=cut

sub load_apps {
	my $self = shift;

	my $dir = $self->{config}{apps_d};

	opendir (my $dh, $dir)
		or croak( __PACKAGE__.": failed to open $dir: $!");

	while (my $fname = readdir $dh) {
		$fname =~ /^\./ and next; # skip dot files
		$self->add_app( "$dir/$fname" );
	};
	closedir $dh;
	return $self;
};

=head2 add_app

=cut

sub add_app {
	my $self = shift;
	my $app = shift;

	defined $app or croak( __PACKAGE__.": Nothing given to add_app" );
	$app = $self->_load_cf( $app );

	# TODO check for consistency

	my @missing = grep { !defined $app->{$_} } qw(name port app);
	@missing and croak( __PACKAGE__
		.": mandatory parameters absent: @missing" );

	my $name = $app->{name};
	my $port = $app->{port};

	# avoid collisions
	if ($self->{apps}{$name} or $self->{ports}{$port}) {
		croak __PACKAGE__.": name or port overlaps";
		# TODO moar details
	};

	$self->{apps}{$name} = $app;
	$self->{ports}{$port} = $app;
	return $self;
};

=head2 del_app

=cut

sub del_app {
	my $self = shift;

	my @apps = $self->get_app_config(@_);

	foreach (@apps) {
		delete $self->{apps}{ $_->{name} };
		delete $self->{ports}{ $_->{port} };
	};
	return $self;
};

=head2 service ( "start|stop|restart|status", [ app_name, ... ] )

Perform SysVInit action. Offload to Daemon::Control.

=cut

sub service {
	my $self = shift;
	my ($action, @list) = @_;

	if (!@list) {
		@list = keys %{ $self->{apps} };
	};

	(!grep { $action eq $_ } qw(start stop restart status))
		and croak( __PACKAGE__.": unknown action $action");

	$action = "do_$action";
	foreach (@list) {
		my $opt = $self->get_init_options($_);
		my $daemon = Daemon::Control->new($opt);
		$daemon->$action();
	};

};

=head2 get_init_options( $service_id )

Get Daemon::Control config for service.

=cut

sub get_init_options {
	my $self = shift;
	my $id = shift;

	my $app = $self->get_app_config($id);

	my $logfile = $self->_format($app->{log_file}, $app);
	my $pidfile = $self->_format($app->{pid_file}, $app);
	my @args = ( "--listen", ":$app->{port}", $app->{app} );
	my %opt = (
		name => "$app->{port} '$app->{name}' ($app->{server})",
		program => $app->{server},
		# TODO more flexible args fmt
		program_args => \@args,
		pid_file => $pidfile,
		stderr_file => $logfile,
		stdout_file => $logfile,
		fork => 2,
	);

	return \%opt;
};

sub _format {
	my $self = shift;
	my ($format, $hash) = @_;

	my %subst = (
		'%' => '%',
		p => $hash->{port},
		n => $hash->{name},
	);

	my $str = $format;
	$str =~ s(%(.))
		(defined $subst{$1} ? $subst{$1}
			: croak __PACKAGE__."Unknown substitute '%$1'"
		)xge;
	return $str;
};

=head2 get_apps

=cut

sub get_apps {
	my $self = shift;
	return keys %{ $self->{apps} }
};

=head2 get_app_config

=cut

sub get_app_config {
	my $self = shift;

	if (wantarray and @_ > 1) {
		croak( __PACKAGE__.":get_app_config: multiple services "
			."requested in scalar context" );
	};

	my $def = $self->{defaults} || {};
	my @fail;
	my @apps;
	foreach (@_) {
		my $app = ($self->{apps}{$_} || $self->{ports}{$_});
		if (!$app) {
			push @fail, $_;
			next;
		};
		$app = { %$def, %$app };
		push @apps, $app;
	};
	@fail and croak( __PACKAGE__.": get_app_config: unknown service(s): @fail");

	return wantarray ? @apps : shift @apps;
};

=head2 clear_apps

=cut

sub clear_apps {
	my $self = shift;

	$self->{apps} = {};
	$self->{ports} = {};
	return $self;
};

sub _load_cf {
	my $self = shift;
	my $raw = shift;

	# TODO more validate
	if (!ref $raw or ref $raw eq 'GLOB') {
		return LoadFile($raw);
	} else {
		return { %$raw }; # shallow copy to avoid storing shared data
	};
};

=head1 AUTHOR

Konstantin S. Uvarin, C<< <khedin at gmail.com> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-plack-initscript at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Plack-InitScript>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Plack::InitScript


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Plack-InitScript>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Plack-InitScript>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Plack-InitScript>

=item * Search CPAN

L<http://search.cpan.org/dist/Plack-InitScript/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2013 Konstantin S. Uvarin.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut

1; # End of Plack::InitScript
