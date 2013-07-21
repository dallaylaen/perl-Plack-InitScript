use 5.006;
use strict;
use warnings FATAL => 'all';

package Plack::InitScript;

=head1 NAME

Plack::InitScript - Manage multiple PSGI applications with one sys V init script.

=head1 SYNOPSIS

Manage multiple psgi applications via sys V init.

    vim /etc/plack/apps.d/foo.yml
    service plack restart foo

More precisely:

    use Plack::InitScript;

    my $cfg = Plack::InitScript->new;
    $cfg->load_config( "/etc/plack/config.yml" );
    $cfg->load_apps;
    $cfg->service( @ARGV ); # start|status|stop|restart, [ service list ]

=head1 HOW IT WORKS

A global plack config is a YAML file with some sane defaults and
location where applications are.

An application config is a YAML file located under certain directory
which contains port, path to executable file, probably human-readable
alias and other stuff like user and group.

Port is believed to be unique id of an application.

After starting an application, a copy of config is stored elsewhere under
<port>.yml if needed to allow stopping it correctly even after its
configuration is removed.

This module only manages configuration. The heavy lifting is outsourced
to C<Daemon::Control>.

=head1 METHODS

=cut

our $VERSION = 0.0114;

use Carp;
use Daemon::Control;
use English;

# use YAML::XS; # TODO eval require, fall back to YAML
use YAML qw(LoadFile DumpFile Dump Load);

use fields qw(
	config ports old_ports alias defaults
	relaxed daemon_class
);
our @SERVICE_FIELDS = qw( app name port user group pid_file log_file
	server server_args env dir );
my %SERVICE_FIELDS;
$SERVICE_FIELDS{$_} = 1 for @SERVICE_FIELDS; # make hash for search

=head1 Public interface

=head2 new

%options may include:

=over

=item * relaxed - skip some checks like required user/group.

=item * daemon_class - replace Daemon::Control with something else.

=back

=cut

sub new {
	my $class = shift;
	my %opt = @_; # TODO unused
	my $self = fields::new($class);

	$self->{relaxed} = $opt{relaxed};
	$self->{daemon_class} = $opt{daemon_class} || "Daemon::Control";

	$self->{$_} = {} for qw(ports old_ports alias);
	return $self;
};

=head2 load_config( $config_file || \%hash )

Load configuartion from file or hash.

=cut

sub load_config {
	my $self = shift;
	my $config = shift;

	$config = $self->_load_cf($config);

	# TODO check config for consistency

	$self->{config} = { %$config }; # shallow copy

	delete $self->{defaults};
	my $def = delete $self->{config}{defaults};
	$def and $self->set_defaults( %$def );

	return $self;
};

=head2 load_apps

Load known applications.

=cut

sub load_apps {
	my $self = shift;

	# TODO warn & should continue if config broken

	# load all apps from config
	my @new = $self->load_dir( $self->{config}{apps_dir} );
	$self->add_app($_) for @new;

	# Load already running apps if specified
	if (defined (my $dir = $self->{config}{old_dir})) {
		my @old = $self->load_dir($dir);
		$self->add_app($_, old => 1) for @old;
	};

	return $self;
};

=head2 service ( "start|stop|restart|status", [ app_name, ... ] )

Perform SysVInit action. Offload to Daemon::Control.

=cut

sub service {
	my $self = shift;
	my $action = shift;

	if ($action eq 'restart') {
		$self->service( stop => @_ );
		return $self->service( start => @_ );
	};
	croak "Unknown action $action"
		unless $action =~ /^(?:start|stop|status)$/;

	my $method = "do_$action";
	my @svc = $self->get_app_config( \@_, old => $action ne 'start' );

	my %stat;
	foreach (@svc) {
		my $opt = $self->get_init_options($_);
		my $daemon = $self->{daemon_class}->new($opt);
		$daemon->$method();
		$self->rm_old_app( $_ ) if $action eq 'stop';
		$self->save_old_app( $_ ) if $action eq 'start';
		$stat{ $_->{port} } = $daemon->read_pid;
	};

	# TODO wait for real start/stop via async ping method
	return \%stat;
};


=head1 Methods for data manipulation

=head2 set_defaults ( %hash )

Set up default values (pid_file, etc) for services.

=cut

sub set_defaults {
	my $self = shift;
	my %def = @_;

	my $olddef = $self->{defaults} || {};
	%def = (%$olddef, %def);

	# Validate defaults
	my @error;
	my @extra = grep { !$SERVICE_FIELDS{$_} } keys %def;
	push @error, "extra keys present: @extra" if @extra;

	# TODO sometimes we need to start as ordinary user,
	# and ordinary user cannot setuid. But we also need to make sure
	# notihng is ever run as root. How?..
	if (!$self->{relaxed}) {
		$def{user} or push @error, "no user";
		$def{group} or push @error, "no group";
	};
	defined $def{log_file} or push @error, "no log_file";
	defined $def{pid_file} or push @error, "no pid_file";
	$def{pid_file} =~ /[^%](%%)*%p/
		or push @error, "pid_file doesn't depend on port";
	defined $def{server} or push @error, "no server";

	@error and croak( __PACKAGE__.": found errors in default values: "
		. join "; ", @error);
	$self->{defaults} = \%def;
	return $self;
};

=head2 add_app ( \%app, %options )

Load application. Options may include:

=over

=item * old - this is info about running app, not configuration.

=back

=cut

sub add_app {
	my $self = shift;
	my ($app, %opt) = @_;
	my $old = $opt{old};
	my $store = $old ? "old_ports" : "ports";

	defined $app or croak( __PACKAGE__.": Nothing given to add_app" );
	$app = $self->_load_cf( $app );
	$app->{old} = 1 if $opt{old};

	# TODO check for consistency

	my @missing = grep { !defined $app->{$_} } qw(port app);
	@missing and croak( __PACKAGE__
		.": mandatory parameters absent: @missing" );

	my $port = $app->{port};

	# avoid collisions
	if ($self->{$store}{$port}) {
		croak __PACKAGE__.": port overlaps: $port";
		# TODO moar details
	};

	# add human readable name
	if (defined (my $alias = $app->{name}) and !$old) {
		croak __PACKAGE__.": alias must not start with digit: $alias"
			if $alias =~ /^\d/;
		croak __PACKAGE__.": alias overlaps: $alias"
			if exists $self->{alias}{$alias};
		$self->{alias}{$alias} = $port;
	};

	$self->{$store}{$port} = $app;
	return $self;
};

=head2 get_init_options( \%app )

Transform hash in internal format into Daemon::Control compatible options.

=cut

sub get_init_options {
	my $self = shift;
	my $app = shift;

	my $logfile = $self->_format($app->{log_file}, $app);
	my $pidfile = $self->_format($app->{pid_file}, $app);
	my $alias = $app->{name} ? "'$app->{name}' " : "";
	my @args = ( "--listen", ":$app->{port}", $app->{app} );
	my %opt = (
		name => "$app->{port} $alias($app->{server})",
		program => $app->{server},
		# TODO more flexible args fmt
		program_args => \@args,
		pid_file => $pidfile,
		stderr_file => $logfile,
		stdout_file => $logfile,
		user => $app->{user},
		group => $app->{group},
		fork => 2,
	);

	return \%opt;
};

# pure
# TODO use String::Format instead?
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

=head2 get_app_config( \@ids, %opt )

Load apps with given ports|aliases. Dies if any isn't found.

Options: "old" = 0|1 - if true, search in "old" array as well.

=cut

sub get_app_config {
	my $self = shift;
	my $list = shift;
	my %opt = @_;

	my @ids = ref $list eq 'ARRAY' ? (@$list) : ($list);
	my $def = $self->{defaults} || {};
	my @search = $opt{old} ? qw(old_ports ports) : "ports";

	if (defined wantarray and !wantarray and @ids != 1) {
		croak __PACKAGE__.":get_app_config: multiple svc requested in"
			." scalar context";
	};

	my @missing;
	if (!@ids) {
		# get ALL ids
		@ids = map { keys %$_ } map { $self->{$_} } @search;
	} else {
		# resolve alias
		foreach (@ids) {
			$_ =~ /^\D/ or next;
			if (my $port = $self->{alias}{$_}) {
				$_ = $port;
			} else {
				push @missing, $_;
			};
		};
	};

	# uniq
	my %known;
	@ids = grep { !$known{$_}++ } @ids;

	# apply defaults
	my @ret;
	PORT: foreach my $port (@ids) {
		foreach (@search) {
			$self->{$_}{$port} or next;
			push @ret, { %$def, %{ $self->{$_}{$port} } };
			next PORT;
		};
	};

	if (@missing) {
		croak __PACKAGE__.":get_app_config: unknown services: "
			. (join " ", @missing, '');
	};

	return wantarray ? @ret : $ret[0];
}; # end get_app_config

=head1 Storage-related methods.

=head2 load_dir( $dir )

Load all apps from given directory.

=cut

sub load_dir {
	my $self = shift;
	my $dir = shift;

	opendir (my $dh, $dir)
		or croak( __PACKAGE__.": failed to open $dir: $!");

	my @ret;
	while (my $fname = readdir $dh) {
		$fname =~ /^\./ and next; # skip dot files
		# TODO carry on if one file dies
		push @ret, $self->_load_cf( "$dir/$fname" );
	};
	closedir $dh;
	return @ret;
};

=head2 save_old_app ( \%app )

Save app to old_dir, if old_dir is present.

=cut

sub save_old_app {
	my $self = shift;
	my $app = shift;

	my $dir = $self->{config}{old_dir};
	DumpFile( "$dir/$app->{port}.yml", $app )
		if $dir;
	return $self;
};

=head2 rm_old_app ( \%app )

Remove app from old_dir, if old_dir is present.

=cut

sub rm_old_app {
	my $self = shift;
	my $app = shift;

	my $dir = $self->{config}{old_dir};
	unlink ("$dir/$app->{port}.yml")
		if $dir; # or die? need to move on...
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
