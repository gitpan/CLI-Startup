# Test reading and writing of RC files

use Test::More;
use Test::Trap;
use Test::Exception;

eval "use CLI::Startup";
plan skip_all => "Can't load CLI::Startup" if $@;

use Cwd;

# Create a temp directory
my $dir    = getcwd();
my $rcfile = "$dir/tmp/rcfile";
mkdir "$dir/tmp";

# Create an RC file for testing. This file contains extra options,
# to verify that writing BACK the file preserves those options,
# even though CLI::Startup doesn't pay any attemption to them
# at all.
open RC, ">", $rcfile or die "Couldn't create $rcfile: $!";
print RC <<EOF;
[default]
foo=1
bar=baz
baz=0

[extras]
a=1
b=2
c=3, 4, 5 ; This will NOT be split into an array!
EOF
close RC or die "Couldn't write $rcfile: $!";

# First test: create an RC file, read it, then write it
# out to a second file, and read the second file. The two
# config hashes should be identical. NOTE: we do it this
# way because there's no reason the FILES should be identical,
# but it's a bug if the configuration data isn't.
{
    local @ARGV = ();

    # Create a CLI::Startup object and read the rc file
    my $app = CLI::Startup->new( {
        rcfile  => $rcfile,
        options => {
            foo     => 'stuff',
            'bar=s' => 'more stuff',
            'baz!'  => 'negatable stuff',
        },
    } );
    $app->init;

    # Config file contents are stored now
    is_deeply $app->get_config,
        {
            default => { foo => 1, bar => 'baz', baz => 0 },
            extras  => { a => 1, b => 2, c => '3, 4, 5', }
        },
        "Config file contents";

    # The "default" section of the config file is copied
    # into the command-line options
    is_deeply $app->get_options, { foo => 1, bar => 'baz', baz => 0 },
        "Command options contents";
    is_deeply $app->get_raw_options, {}, "No command-line options";

    # Write the current settings to a second file for comparison
    $app->write_rcfile("$rcfile.check");
    ok -r "$rcfile.check", "File was created";

    my $app2 = CLI::Startup->new({ foo => 'bar' });
    $app2->set_rcfile("$rcfile.check");
    $app2->init;

    # Writing and reading the file should be idempotent
    is_deeply $app->get_config, $app2->get_config, "Config settings match";
}

# Reading a nonexistent file silently succeeds
{
    my $app3 = CLI::Startup->new({
        rcfile  => "$dir/tmp/no_such_file",
        options => { foo => 'bar' },
    });
    lives_ok { $app3->init } "Init with nonexistent file";
    is_deeply $app3->get_config, { default => {} }, "Config is empty";
}

# Repeat the above, using a command-line argument instead of
# an option in the constructor.
{
    local @ARGV = ( "--rcfile=$dir/tmp/no_such_file" );
    my $app = CLI::Startup->new({ foo => 'bar' });
    lives_ok { $app->init } "Init with command-line rcfile";
    ok $app->get_rcfile eq "$dir/tmp/no_such_file", "rcfile set correctly";
    is_deeply $app->get_config, { default => {} }, "Config is empty";
}

# Call init() for a nonexistent rc file, then write back the
# config, and read in the config file in a second app object.
# The config data should match.
{
    my $file = "$dir/tmp/auto";

    local @ARGV = (
        "--rcfile=$file", qw/ --write-rcfile --foo --bar=baz /
    );
    my $app = CLI::Startup->new({
        options => {
            foo     => 'foo option',
            'bar=s' => 'bar option',
        },
    });
    lives_ok { $app->init } "Init with nonexistent command-line rcfile";
    ok $app->get_rcfile eq "$file", "rcfile set correctly";
    is_deeply $app->get_config, { default => {} }, "Config is initially empty.";
    ok -r "$file", "File was created";

    my $app2 = CLI::Startup->new({
        rcfile  => "$file",
        options => { foo => 'bar' },
    });
    $app2->init;
    is_deeply $app2->get_config, { default => { foo => 1, bar => 'baz' }},
        "Writeback is idempotent";
}

# Specify a config file in the constructor, then change it, and
# THEN specify a different config file on the command line. The
# one on the command line should win.
{
    # Create a CLI::Startup object and read the rc file
    my $app = CLI::Startup->new( {
            rcfile  => '/foo',
            options => { foo => 'bar' },
    } );
    ok $app->get_rcfile eq '/foo', "Set rcfile in constructor";

    $app->set_rcfile('/bar');
    ok $app->get_rcfile eq '/bar', "Changed rcfile in mutator";

    local @ARGV = ('--rcfile=/baz');
    $app->init();
    ok $app->get_rcfile eq '/baz', "Command line override rcfile";
}

# Specify a blank config-file name, then try to write it. That should
# fail with an error.
{
    my $app = CLI::Startup->new({
        rcfile  => '',
        options => { foo => 'bar' },
    });
    ok $app->get_rcfile eq '', "Set blank rcfile name";

    local @ARGV = ('--write-rcfile');
    trap { $app->init() };

    ok $trap->leaveby eq 'die', "App died trying to write file";
    like $trap->die, qr/no file specified/, "Correct error message";
}

# Specify a blank config file on the command line. That should also fail.
{
    my $app = CLI::Startup->new({ foo => 'bar' });

    local @ARGV = ('--rcfile', '', '--write-rcfile');
    trap { $app->init() };

    ok $trap->leaveby eq 'die', "Error exit trying to write file";
    like $trap->die, qr/no file specified/, "Correct error message";
}

# Don't specify any config file on the command line. That should also fail.
{
    my $app = CLI::Startup->new({ foo => 'bar' });

    local @ARGV = ('--rcfile=', '--write-rcfile');
    trap { $app->init() };

    ok $trap->leaveby eq 'die', "Error exit trying to write file";
    like $trap->die, qr/no file specified/, "Correct error message";
}

# Specify a custom rcfile writer
{
    my $app = CLI::Startup->new({
        write_rcfile => sub { print "writer called" },
        options      => { foo => 'bar' },
    });
    ok $app->get_write_rcfile, "Custom writer defined";

    local @ARGV = ('--write-rcfile');
    trap { $app->init() };

    ok $trap->leaveby eq 'return', "Custom writer returned normally";
    like $trap->stdout, qr/writer called/, "Writer was indeed called";
}

# Disable rcfile writing
{
    my $app = CLI::Startup->new({
        write_rcfile => undef,
        options      => { foo => 'bar' },
    });
    ok !$app->get_write_rcfile, "--write-rcfile disabled";

    local @ARGV = ('--write-rcfile');

    # Command-line option will simply be unrecognized
    trap { $app->init() };
    ok $trap->exit == 1, "Error exit with disabled --write-rcfile";
    like $trap->stderr, qr/Unknown option/, "Unknown option error message";

    # Forcibly requesting a writeback from code should die
    trap { $app->init(); $app->write_rcfile };
    ok $trap->leaveby eq 'die', "Dies when forced to write rcfile";
    like $trap->die, qr/but called anyway/, "Correct error message";
}

# Read various different types of RC file
{
    # This is what the configs should all match.
    my $config = {
        default => {
            foo => 'bar',
            bar => 'baz',
        },
    };

    # First: Bare name/value pairs
    open OUT, ">", $rcfile;
    print OUT "foo=bar\nbar=baz\n";
    close OUT;

    my $app1 = CLI::Startup->new({
        rcfile  => $rcfile,
        options => { a => 1 },
    });
    $app1->init;

    is_deeply $app1->get_config, $config, "Simple config matches";

    SKIP: {
        eval "use YAML::Any";
        skip("YAML::Any is not installed", 1) if $@;

        # Next, if available: YAML config
        open OUT, ">", $rcfile;
        print OUT "---\ndefault:\n  foo: bar\n  bar: baz\n";
        close OUT;

        my $app2 = CLI::Startup->new({
            rcfile  => $rcfile,
            options => { a => 1 },
        });
        $app2->init;

        is_deeply $app2->get_config, $config, "YAML matches simple config";
    }


    # INI-style file
    open OUT, ">", $rcfile;
    print OUT "[default]\nfoo=bar\nbar=baz\n";
    close OUT;

    my $app3 = CLI::Startup->new({
        rcfile  => $rcfile,
        options => { a => 1 },
    });
    $app3->init;

    is_deeply $app3->get_config, $config, "INI file matches simple config";

    SKIP: {
        eval "use JSON::Any";
        skip("JSON::Any is not installed", 1) if $@;

        # JSON config file
        open OUT, ">", $rcfile;
        print OUT qq{{\n    "default": {\n        "bar":"baz",\n        "foo":"bar"\n}\n}};
        close OUT;

        my $app5 = CLI::Startup->new({
            rcfile  => $rcfile,
            options => { a => 1 },
        });
        $app5->init;

        is_deeply $app5->get_config, $config, "JSON matches simple config";
    }

    SKIP: {
        eval "use XML::Simple";
        skip("XML::Simple is not installed", 1) if $@;

        # XML config file
        open OUT, ">", $rcfile;
        print OUT "<opt>\n  <default bar=\"baz\" foo=\"bar\" />\n</opt>\n";
        close OUT;

        my $app6 = CLI::Startup->new({
            rcfile  => $rcfile,
            options => { a => 1 },
        });
        $app6->init;

        is_deeply $app6->get_config, $config, "XML matches simple config";
    }
}

# Read a more complicated RC file in YAML syntax
SKIP: {
    eval "use YAML::Any";
    skip("YAML::Any is not installed", 1) if $@;

    # Create the file
    open OUT, ">", $rcfile;
    print OUT <<EOF;
---
default:
  foo: bar
  bar: baz
  baz: [ 1, 2, 3 ]
  qux: { a: 1, b: 2, c: 3 }
EOF
    close OUT;

    my $app = CLI::Startup->new({
        rcfile  => $rcfile,
        options => {
            'foo=s'  => 1,
            'bar=s'  => 1,
            'baz=i@' => 1,
            'qux=s%' => 1,
        },
    });
    $app->init;

    my $config = {
        default => {
            foo => 'bar',
            bar => 'baz',
            baz => [ 1, 2, 3 ],
            qux => { a => 1, b => 2, c => 3 },
        }
    };

    is_deeply $app->get_config, $config, "More complicated YAML config";
}

# Command-line overrides contents of rcfile
{
    open OUT, ">", $rcfile;
    print OUT <<EOF;
foo=bar
bar=qux
EOF
    close OUT;

    my $app = CLI::Startup->new({
        rcfile  => $rcfile,
        options => { 'foo=s' => 'foo', 'bar=s' => 'bar' },
    });

    local @ARGV = ('--foo=baz');
    $app->init;
    ok $app->get_options->{foo} eq 'baz', "Options override rcfile";
    ok $app->get_options->{bar} eq 'qux', "Value taken from rcfile";
    is_deeply $app->get_raw_options, { foo => 'baz' }, "Raw command-line options";
}

# rcfile with listy settings
{
    open OUT, ">", $rcfile;
    print OUT <<EOF;
x=a
EOF
    close OUT;

    my $app = CLI::Startup->new({
        rcfile  => $rcfile,
        options => { 'x=s@' => 'x option' },
    });
    $app->init;

    ok ref($app->get_options->{x}) eq 'ARRAY', "Option was listified";
    is_deeply $app->get_raw_options, {}, "No command-line options";
}

# rcfile with multiple listy options
{
    open OUT, ">", $rcfile;
    print OUT <<EOF;
x=a,b,c, d
EOF
    close OUT;

    my $app = CLI::Startup->new({
        rcfile  => $rcfile,
        options => { 'x=s@' => 'x option' },
    });
    $app->init;

    is_deeply $app->get_options->{x}, [qw/a b c d/], "Listy option";
    is_deeply $app->get_raw_options, {}, "No command-line options";
}

# rcfile with hashy settings
{
    open OUT, ">", $rcfile;
    print OUT <<EOF;
x=a=1, b=2, c=3=3
EOF
    close OUT;

    my $app = CLI::Startup->new({
        rcfile  => $rcfile,
        options => { 'x=s%' => 'x option' },
    });
    $app->init;

    is_deeply $app->get_options->{x}, {a=>1, b=>2, c=>'3=3'},
        "Option was hashified";
    is_deeply $app->get_raw_options, {}, "No command-line options";
}

# rcfile with a single hashy setting
{
    open OUT, ">", $rcfile;
    print OUT <<EOF;
x=a=1
EOF
    close OUT;

    my $app = CLI::Startup->new({
        rcfile  => $rcfile,
        options => { 'x=s%' => 'x option' },
    });
    $app->init;

    is_deeply $app->get_options->{x}, {a=>1}, "Single hashy option";
    is_deeply $app->get_raw_options, {}, "No command-line options";
}

# rcfile with empty-valued hash setting
{
    open OUT, ">", $rcfile;
    print OUT <<EOF;
x=a=
y=a
EOF
    close OUT;

    my $app = CLI::Startup->new({
        rcfile  => $rcfile,
        options => { 'x=s%' => 'x option', 'y=s%' => 'y option' },
    });
    $app->init;

    is_deeply $app->get_options->{x}, {a=>''}, "Blank-valued hashy option";
    is_deeply $app->get_options->{y}, {a=>''}, "Blank-valued hashy option";
    is_deeply $app->get_raw_options, {}, "No command-line options";
}

# Clean up
unlink $_ for glob("$dir/tmp/*");
rmdir "$dir/tmp";

done_testing();
