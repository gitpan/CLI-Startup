use strict;
use warnings;

use Module::Build;

my $class = Module::Build->subclass( code => <<'EOF' );

    sub ACTION_authortest {
        my ($self) = @_;

        $self->depends_on('build');
        $self->depends_on('manifest');
        $self->depends_on('distmeta');

        $self->test_files( qw< t xt/ > );
        $self->recursive_test_files(1);

        $self->depends_on('test');

        return;
    }

    sub ACTION_distdir {
        my ($self) = @_;

        $self->depends_on('authortest');

        return $self->SUPER::ACTION_distdir();
    }
EOF

my $builder = $class->new(
    module_name         => 'CLI::Startup',
    license             => 'perl',
    dist_author         => q{Len Budney <len.budney@gmail.com>},
    dist_version_from   => 'lib/CLI/Startup.pm',

    requires => {
        perl              => '5.8.8',
        'Class::Std'      => '0.01',
        'Clone'           => 0,
        'Config::Any'     => 0,
        'Config::Tiny'    => 0,
        'Config::General' => 0,
        'File::Basename'  => 0,
        'File::HomeDir'   => '0.97',
        'Getopt::Long'    => '2.38',
        'Hash::Merge'     => 0,
        'List::Util'      => 0,
        'Pod::Text'       => '3.01',
        'Text::CSV'       => 0,
    },

    recommends => {
        'JSON::Any'           => 0,
        'YAML::Any'           => 0,
        'XML::Simple'         => 0,
        'Config::INI::Writer' => 0,
    },

    build_requires => {
        'Test::More'      => 0,
        'Test::Trap'      => 0,
        'Test::Exception' => 0,
    },

    configure_requires => {
        'Module::Build' => 0.33,
    },

    add_to_cleanup      => [qw{
        *.bak
        CLI-Startup-*
    }],
    create_makefile_pl => 'traditional',
);

$builder->create_build_script();
