use 5.006;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'Plack::InitScript',
    AUTHOR              => q{Konstantin S. Uvarin <khedin@gmail.com>},
    VERSION_FROM        => 'lib/Plack/InitScript.pm',
    ABSTRACT_FROM       => 'lib/Plack/InitScript.pm',
    ($ExtUtils::MakeMaker::VERSION >= 6.3002
      ? ('LICENSE'=> 'perl')
      : ()),
    PL_FILES            => {},
    PREREQ_PM => {
        'Test::More' => 0,
        'YAML' => 0,
        'Daemon::Control' => 0,
        'Carp' => 0,
    },
    BUILD_REQUIRES => {
        'Test::Exception' => 0,
        'Data::Dumper' => 0,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'Plack-InitScript-*' },
);
