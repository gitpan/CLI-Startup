package CLI::Startup;

use English qw( -no_match_vars );

use warnings;
use strict;

use Symbol;
use Pod::Text;
use Text::CSV;
use Class::Std;
use Config::Any;
use Data::Dumper;
use Getopt::Long;
use File::HomeDir;
use File::Basename;
use Clone qw{ clone };
use Hash::Merge qw{ merge };
use List::Util qw{ max reduce };

use base 'Exporter';
our @EXPORT_OK = qw/startup/;

our $VERSION = '0.11';

# Simple command-line processing with transparent
# support for config files.
sub startup
{
    my $optspec = shift;

    my $app = CLI::Startup->new($optspec);
    $app->init;

    return $app->get_options;
}

# Attributes of our inside-out objects.
my %config_of : ATTR();
my %default_settings_of :ATTR( :get<default_settings> :initarg<default_settings> );
my %initialized_of :ATTR( :get<initialized> );
my %options_of :ATTR();
my %optspec_of : ATTR( :initarg<optspec> );
my %raw_options_of :ATTR();
my %rcfile_of : ATTR( :get<rcfile> :initarg<rcfile> );
my %usage_of : ATTR( :get<usage> :initarg<usage> );
my %write_rcfile_of : ATTR( :get<write_rcfile> :initarg<write_rcfile> );

# Returns a clone of the config object.
sub get_config
{
    my $self = shift;
    $self->die('get_config() called before init()')
        unless $self->get_initialized;
    return clone($config_of{ident $self});
}

# Set defaults for the command-line options. Can be done as much as
# desired until the app is initialized.
sub set_default_settings
{
    my ($self, $settings) = @_;

    $self->die('set_default_settings() requires a hashref')
        unless defined $settings and ref $settings eq 'HASH';
    $self->die('set_default_settings() called after init()')
        if $self->get_initialized;

    $default_settings_of{ident $self} = clone($settings);

    return; # Needed so we don't leak a reference to the data!
}

# Get the options provided on the command line. This, unlike most of
# the others, can ONLY be called after the app is initialized.
sub get_options
{
    my $self = shift;
    $self->die('get_options() called before init()')
        unless $self->get_initialized;
    return clone( $options_of{ident $self} );
}

# Returns the current specifications for the command-line options.
sub get_optspec
{
    my $self = shift;
    return clone( $optspec_of{ident $self} );
}

# Set the specifications of the current command-line options.
sub set_optspec
{
    my $self = shift;
    my $spec = shift;

    $self->die('set_optspec() requires a hashref')
        unless ref $spec eq 'HASH';
    $self->die('set_optspec() called after init()')
        if $self->get_initialized;

    $optspec_of{ident $self} = clone($self->_validate_optspec($spec));

    return; # Needed so we don't leak a reference to the data!
}

# Returns a clone of the actual command-line options.
sub get_raw_options
{
    my $self = shift;
    $self->die('get_raw_options() called before init()')
        unless $self->get_initialized;
    return clone( $raw_options_of{ident $self} );
}

# Set the filename of the rcfile for the app.
sub set_rcfile
{
    my ($self, $rcfile) = @_;

    $self->die('set_rcfile() called after init()')
        if $self->get_initialized;
    $rcfile_of{ident $self} = "$rcfile";

    return;
}

# Set the usage string for the app. Only needed if there are
# arguments other than command-line options.
sub set_usage
{
    my ($self, $usage) = @_;

    $self->die('set_usage() called after init()')
        if $self->get_initialized;
    $usage_of{ident $self} = "$usage";

    return;
}

# Set a file writer for the rc file.
sub set_write_rcfile
{
    my $self   = shift;
    my $writer = shift || 0;

    $self->die('set_write_rcfile() called after init()')
        if $self->get_initialized;
    $self->die('set_write_rcfile() requires a coderef or false')
        if $writer && ref($writer) ne 'CODE';

    my $optspec = $optspec_of{ident $self}; # Need a reference, not a copy

    # Toggle the various rcfile options if writing is turned on or off
    if ($writer)
    {
        my $options = $self->_get_default_optspec;
        my $aliases = $self->_option_aliases($options);

        for my $alias ( qw{ rcfile write-rcfile rcfile-format } )
        {
            $optspec->{$alias} ||= $options->{$aliases->{$alias}};
        }
    }
    else
    {
        for my $alias ( qw{ rcfile write-rcfile rcfile-format } )
        {
            delete $optspec->{$alias};
        }
    }

    # Save the writer
    $write_rcfile_of{ident $self} = $writer;

    return; # Needed so we don't leak a reference to the data!
}

# Die with a standardized message format.
sub die                         ## no critic ( Subroutines::RequireFinalReturn )
{
    my $self = shift;
    my $msg  = shift;
    my $name = basename($PROGRAM_NAME);

    CORE::die "$name: FATAL: $msg\n";
}

# Die with a usage summary.
sub die_usage
{
    my $self    = shift;
    my $optspec = $self->get_optspec;

    # This happens if options aren't defined in the constructor
    # and then die_usage() is called directly or indirectly.
    $self->die('die_usage() called without defining any options')
        unless keys %{$optspec};

    # In the usage text, show the option names, not the aliases.
    my %options =
        map { ( $_->{names}[0], $_ ) }
        map { $self->_parse_spec($_) }
        keys %{$optspec};

    # Note the length of the longest option
    my $length  = max map { length($_) } keys %options;

    # Now print the help message.
    print 'usage: ' . basename($PROGRAM_NAME) . ' ' . $self->get_usage . "\n";
    print "Options:\n";

    # Print the options, sorted in dictionary order.
    for my $option (sort keys %options)
    {
        ## no critic (ValuesAndExpressions::ProhibitMagicNumbers)
        my $indent = $length + 6;
        my $spec   = $options{$option};

        # Print the basic help option
        printf "    %-${length}s - %s\n", $option, $spec->{desc};

        # Print aliases, if any
        if (@{ $spec->{names} } > 1)
        {
            my @aliases = @{ $spec->{names} };
            shift @aliases;

            printf "%${indent}s Aliases: %s\n", '', join(', ', @aliases);
        }

        # Print negation, if any
        if ($spec->{bool})
        {
            printf "%${indent}s Negate this with --no-%s\n", '', $option;
        }
    }

    exit 1;
}

# Returns the "default" optspec, consisting of options
# that CLI::Startup normally creates automatically.
sub _get_default_optspec
{
    return {
        'help'            => 'Print this helpful help message',
        'rcfile=s'        => 'Config file to load',
        'write-rcfile'    => 'Write current options to rcfile',
        'rcfile-format=s' => 'Format to write the rcfile',
        'version'         => 'Print version information and exit',
        'manpage'         => 'Print the manpage for this script',
    };
}

# Parses the option specs, identifying their data types
sub _parse_specs
{
    my $self = shift;

    my %structure;

    # Build a list of the array and hash configs, so we can
    # unflatten them from the config file if necessary.
    for my $option ( keys %{ $self->get_optspec } )
    {
        my $spec = $self->_parse_spec($option);

        for my $type (qw{ array hash bool flag })
        {
            next unless $spec->{$type};
            $structure{$_} = uc($type) for @{$spec->{names}};
        }
    }

    return \%structure;
}

# Breaks an option spec down into its components.
sub _parse_spec
{
    my ($self, $spec) = @_;

    # We really want the "name(s)" portion
    my ( $specification, $type1, $type2 ) =
        $spec =~ /^([^:=!+]+)([:=!+]?)[^@%]*([@%]?).*$/xms;

    # Lookup the help text while we're at it
    my $optspec = $self->get_optspec;

    ## no critic ( ValuesAndExpressions::ProhibitNoisyQuotes )

    # Note: doesn't identify string, int, float options
    return {
        spec   => $spec,
        names  => [ split /[|]/xms, $specification ],
        desc   => $optspec->{$spec},
        array  => ( $type2 eq '@' ? 1 : 0 ),
        hash   => ( $type2 eq '%' ? 1 : 0 ),
        bool   => ( $type1 eq '!' ? 1 : 0 ),
        flag   => ( $type1 eq ''  ? 1 : 0 ),
    };
}

# Returns a hash of option aliases and specifications from the
# supplied hash. Also converts undef to 0 in $optspec.
sub _option_aliases
{
    my ($self, $optspec ) = @_;
    my %option_aliases;

    # Make sure that there are no duplicated option names,
    # and that options with undefined help text are defined
    # to false.
    for my $option (keys %{$optspec})
    {
        $optspec->{$option} ||= 0;
        $option               = $self->_parse_spec($option);

        # The spec can define aliases
        for my $name ( @{ $option->{names} } )
        {
            $self->die("--$name option defined twice") if exists $option_aliases{$name};
            $option_aliases{$name} = $option->{spec};
        }
    }

    return \%option_aliases;
}

# Returns an options spec hashref, with automatic options
# added in.
sub _validate_optspec
{
    my ( $self, $optspec ) = @_;

    # Build a hash of option specs in $optspec, indexed by option name.
    # Die with an error if any option names collide.
    my $option_aliases  = $self->_option_aliases($optspec);
    my $default_options = $self->_get_default_optspec;
    my $default_aliases = $self->_option_aliases($default_options);

    # Verify that any default options specified in $optspec are specified
    # with the right signature OR are bare words. This makes for the
    # syntactic sugar of saying { rcfile => 0 } instead of { 'rcfile=s' => 0 }.
    for my $name ( keys %{$default_aliases} )
    {
        # If an alias in $default_aliases is not mentioned in $options_aliases,
        # then install the option in $optspec.
        if ( not exists $option_aliases->{$name} )
        {
            my $specification = $default_aliases->{$name};
            $optspec->{$specification} = $default_options->{$specification};
            next;
        }
        my $specification = delete $option_aliases->{$name};

        # If the alias $name has the same specification as in the default
        # options, then there's nothing to do.
        next if $specification eq $default_aliases->{$name};

	    # Otherwise it's a fatal error for the specification to be
	    # more than a bare word, possibly with aliases. The bare word is
        # interpreted as a shorthand for the full specificaion of the
        # default option.
        my $details = $self->_parse_spec($specification);
        if ( not $details->{flag} )
        {
            $self->die("--$name option defined incorrectly; should be \"$_\"")
                for ($default_aliases->{$name});
        }

        # We've handled this option, so skip any aliases it may have.
        delete $option_aliases->{$_} for @{ $details->{names} };

        # We consider the specification we found to be a replacement for
        # the default specification, so we delete the default one as
        # redundant with the one we found.
        delete $optspec->{$default_aliases->{$name}};
    }

    # The --help option is NOT optional, so we override it if it evaluates
    # to false. It must be present, because if we didn't find it above we
    # would have inserted it.
    $optspec->{help} = $default_options->{help} unless $optspec->{help};

    # If the --rcfile option is disabled, then we must also delete the
    # --rcfile-format and --write-rcfile options, since they make no
    # sense in scripts that don't support config files.
    if ( not $optspec->{$default_aliases->{rcfile}} )
    {
        delete $optspec->{$default_aliases->{$_}}
            for qw{ rcfile rcfile-format write-rcfile };
    }

    # If rcfile writing is disabled, then we must delete the --rcfile-format
    # option, which is meaningless when we don't write config files.
    if ( not $optspec->{$default_aliases->{'write-rcfile'}} )
    {
        delete $optspec->{$default_aliases->{'rcfile-format'}};
    }

    # Remove any other disabled options. Options are disabled by
    # setting them to anything that evaluates to false. We made
    # sure it was defined in the call to _parse_spec() above.
    map { delete $optspec->{$_} unless $optspec->{$_} } keys %{$optspec};

    return $optspec;
}

# This is the core method of the whole module: it actually does the
# command-line processing, config-file reading, etc.. Once it
# completes, most of the write accesors are disabled, and this
# object becomes a reference for looking up configuration info.
sub init
{
    my $self = shift;

    $self->die('init() method takes no arguments') if @_;
    $self->die('init() called a second time')
        if $self->get_initialized;

    # It's a fatal error to call init() without defining any
    # command-line options
    $self->die('init() called without defining any command-line options')
        unless $self->get_optspec || 0;

    # Parse command-line options, then read the config file if any.
    my $options = $self->_process_command_line;
    my $config  = $self->_read_config_file;
    my $default = $self->get_default_settings();

    # Save the unprocessed command-line options
    $raw_options_of{ident $self} = clone($options);

    # Now, combine the command options, the config-file defaults,
    # and the wired-in app defaults, in that order of precedence.
    $options = reduce { merge($a,$b) } (
        $options, $config->{default}, $default
    );

    # Save the fully-processed options
    $options_of{ident $self} = clone($options);

    # Mark the object as initialized
    $initialized_of{ident $self} = 1;

    #
    # Automatically processed options:
    #

    # Print the version information, if requested
    $self->print_version if $options->{version};

    # Print the POD manpage from the script, if requested
    $self->print_manpage if $options->{manpage};

    # Write back the config if requested
    $self->write_rcfile if $options->{'write-rcfile'};

    return;
}

sub _process_command_line
{
    my $self    = shift;
    my $optspec = $self->get_optspec;
    my %options;

    # Parse the command line and die if anything is wrong.
    my $opts_ok = GetOptions( \%options, keys %{$optspec} );
    $self->die_usage if $options{help} || !$opts_ok ;

    # Treat array and hash options as CSV records, so we can
    # cope with quoting and values containing commas.
    my $csv = Text::CSV->new({ allow_loose_quotes => 1 });

    # Further process the array and hash options
    for my $option (keys %options)
    {
        if ( ref $options{$option} eq 'ARRAY' )
        {
            my @values;
            for my $value (@{$options{$option}})
            {
                $csv->parse($value)
                    or $self->die("Can't parse --$option option: $value");
                push @values, $csv->fields;
            }

            $options{$option} = \@values;
        }
    }

    # Process the rcfile option immediately, to override any settings
    # hard-wired in the app, as well as this module's defaults. If the
    # rcfile has already been set to a false value, however, then this
    # option is disallowed.
    $self->set_rcfile($options{rcfile}) if defined $options{rcfile};

    # That's it!
    return \%options;
}

sub _read_config_file
{
    my $self    = shift;
    my $types   = $self->_parse_specs;
    my $rcfile  = $self->get_rcfile || '';
    my $options = {
        files         => [$rcfile],
        use_ext       => 0,
        force_plugins => [qw{
	        Config::Any::INI Config::Any::XML Config::Any::YAML
	        Config::Any::JSON Config::Any::Perl
        }],
    };

    my $raw_config;

    # Attempt to parse the file, if any
    if ( $rcfile && -r $rcfile )
    {
        # Defend against badly configured parsers. I'm looking
        # at YOU, XML::SAX!
        local $SIG{__WARN__} = sub {
            my @args = @_;

            for my $arg (@args)
            {
                next if ref $arg;
                return if $arg =~ /Unable to recognise encoding/;
                return if $arg =~ /ParserDetails\.ini/;
            }

            CORE::warn(@args);
        };

        # OK, NOW load the files.
        my $files   = Config::Any->load_files( $options );
        $files      = shift @{$files} || {};
        $raw_config = $files->{$rcfile} || {};
    }
    else
    {
        $raw_config = {};
    }

    # Initialize an empty config
    my $config = { default => {} };

    # Copy in the default section, if there is one.
    if ( defined $raw_config->{default} )
    {
        if ( ref $raw_config->{default} ne 'HASH' )
        {
            $self->die("Config file's \"default\" setting isn't a hash!");
        }
        else
        {
            $config->{default} = delete $raw_config->{default};
        }
    }

    # Now parse strings if they're supposed to be hashes or arrays.
    # This is basically a fix for file formats like INI, that can't
    # encode data structures.

    # Step through the config, moving any scalars we see into the
    # default section.
    for my $key ( keys %{$raw_config} )
    {
        # We expect a hash, with a "default" section, but if there
        # isn't one, or there are naked options, then we treat them
        # as defaults.
        if ( not ref $raw_config->{$key} )
        {
            $config->{default}{$key} = delete $raw_config->{$key};
            next;
        }
        else
        {
            $config->{$key} = delete $raw_config->{$key};
        }
    }

    # Now step through the default section, turning scalars into
    # arrays and hashes as necessary.
    for my $option ( keys %{ $config->{default} } )
    {
        my $value = $config->{default}{$option};
        $value    = $self->_parse_setting( $value, $option, $types );

        $config->{default}{$option} = $value;
    }

    # Save the cleaned-up config for reference
    $config_of{ident $self} = $config;

    return $config;
}

# Convert string values into an arrayref or hashref as needed
sub _parse_setting
{
    my ($self, $value, $option, $types) = @_;

    # If the data is the right type, or we have no spec, nothing to do.
    my $type = $types->{$option} || 'NONE';
    return $value if ref $value eq $type or $type eq 'NONE';

    # All other data types we support are scalars.
    $self->die("Bad data type for \"$option\" option in config file.")
        if ref $value;

    # Boolean or flags are converted to boolean. Booleans are just
    # negatable flags.
    if ( $type eq 'BOOL' or $type eq 'FLAG' )
    {
        return $value ? 1 : 0;
    }

    # The only fix we implement is to parse CSV and primitive name/value
    # pairs.
    my $csv  = Text::CSV->new({
        allow_loose_quotes => 1,
        allow_whitespace   => 1,
    });

    # Start by turning the string to an array
    $csv->parse($value);
    $value = [ $csv->fields ];
    return $value if $type eq 'ARRAY';

    my %hash;

    # Now it has to be a hash, so we need to split the values
    # on equal signs or colons.

    for (@{$value})
    {
        my ($key, $val) = m/^([^=:]+)(?:\s*[:=]\s*)?(.*)$/xms;
        $hash{$key} = $val;
    }

    return \%hash;
}

# Constructor for this object.
sub BUILD
{
    my ($self, $id, $argref) = @_;

    # Shorthand: { options => \%options } can be
    # abbreviated \%options.
    if ( not exists $argref->{options} )
    {
        $argref = { options => $argref };
    }
    $self->set_optspec($argref->{options}) if keys %{$argref->{options} || {}};

    # Caller can specify default settings for all options.
    $self->set_default_settings($argref->{default_settings})
        if exists $argref->{default_settings};

    ## no critic ( ValuesAndExpressions::ProhibitNoisyQuotes )

    # Setting rcfile to undef in the constructor disables rcfile reading
    # for the script.
    $self->set_rcfile(
          exists $argref->{rcfile}
        ? $argref->{rcfile}
        : File::HomeDir->my_home . '/.' . basename($PROGRAM_NAME) . 'rc'
    );

    # Caller can forbid writing of rcfiles by setting
    # the write_rcfile option to undef, or can supply
    # a coderef to do the writing.
    if ( exists $argref->{write_rcfile} )
    {
        $self->set_write_rcfile( $argref->{write_rcfile} );
    }

    # Set an optional usage message for the script.
    $self->set_usage(
          exists $argref->{usage}
        ? $argref->{usage}
        : '[options]'
    );

    return;
}

# Prints out the POD contained in the script file, if any.
sub print_manpage
{
    my $self   = shift;
    my $parser = Pod::Text->new;

    $parser->output_fh(*STDOUT);
    $parser->parse_file($PROGRAM_NAME);
    $self->die_usage unless $parser->content_seen;

    exit 0;
}

# Prints the version of the script.
sub print_version
{
    my $self    = shift;
    my $version = $::VERSION || 'UNKNOWN';
    my $name    = basename($PROGRAM_NAME);

    print {\*STDERR} <<"EOF";
This is $name, version $version
    path: $PROGRAM_NAME
    perl: $PERL_VERSION
EOF
    exit 0;
}

# Print a nicely-formatted warning message.
sub warn
{
    my $self = shift;
    my $msg  = shift;
    my $name = basename($PROGRAM_NAME);

    CORE::warn "$name: WARNING: $msg\n";

    return;
}

# Writes the config file in the specified format.
sub write_rcfile
{
    my $self = shift;
    my $file = shift || $self->get_rcfile;

    # It's a fatal error to call write_rcfile() before init()
    $self->die('write_rcfile() called before init()')
        unless $self->get_initialized;

    # If there's no file to write, abort.
    $self->die('Write rcfile: no file specified') unless $file;

    # Check whether a writer has been set
    my $writer = $self->_choose_rcfile_writer;

    # If there's a writer, call it.
    if ( ref $writer eq 'CODE' )
    {
        $writer->($self, $file);
    }
    else
    {
        $self->die('write_rcfile() disabled, but called anyway');
    }

    return;
}

# Returns a hashref that looks like a config file's contents, with
# the defaults overwritten by the options used for the current
# invocation of the script.
sub get_options_as_defaults
{
    my $self = shift;

    # Collate the settings for writing
    my $settings        = $self->get_config;
    my $options         = $self->get_raw_options;
    my $default         = $self->get_default_settings;
    my $default_aliases = $self->_option_aliases($self->_get_default_optspec);

    # Copy the current options back into the "default" group
    $settings->{default} = reduce { merge($a,$b) } (
        $options, $settings->{default}, $default
    );

    # Delete settings for the automatically-generated options; none of them
    # belong in the rcfile.
    for my $option (keys %{$default_aliases})
    {
        delete $settings->{default}{$option};
    }

    return $settings;
}

# Choose the correct built-in config writer based on the current
# value of --rcfile-format.
sub _choose_rcfile_writer
{
    my $self = shift;

    # If a writer was specified by the user, we don't have to think.
    # If it evaluates to false, or isn't a coderef, write_rcfile()
    # will abort with an error.
    if ( exists $write_rcfile_of{ident $self} )
    {
        return $write_rcfile_of{ident $self};
    }

    my $writer = {
        INI  => \&_write_rcfile_ini,
        XML  => \&_write_rcfile_xml,
        JSON => \&_write_rcfile_json,
        YAML => \&_write_rcfile_yaml,
        PERL => \&_write_rcfile_perl,
    };

    # Decide what the default should be: INI falling back on Perl
    eval 'use Config::INI::Writer';
    my $default = $EVAL_ERROR ? 'PERL' : 'INI';

    # Check whether a file format was specified; if not, use the default.
    my $options = $self->get_options;
    my $format  = uc( $options->{'rcfile-format'} || $default );

    $self->die("Unknown --rcfile-format option specified: \"$format\"")
        unless defined $writer->{$format};

    return $writer->{$format};
}

# Write the current settings to an INI file. Serialize hash and array
# values for known command-line options. Leave everything else alone.
sub _write_rcfile_ini
{
    my ($self, $file) = @_;

    # Installing the INI module is optional
    eval 'use Config::INI::Writer';
    $self->die('Can\'t write rcfile: Config::INI::Writer is not installed.')
        if $EVAL_ERROR;

    # Get out current settings, and then fix the formats of array and
    # hash values.
    my $settings = $self->get_options_as_defaults;
    my $types    = $self->_parse_specs;

    for my $setting ( keys %{ $settings->{default} } )
    {
        my $value = $settings->{default}{$setting};

        # String data doesn't need anything done to it.
        next unless ref $value;

        # We produce compliant CSV; no options needed.
        my $csv = Text::CSV->new;

        # Serialize the two structures we know about.
        if ( ref $value eq 'ARRAY' )
        {
            # Just stringify. Deep structure will be silently lost.
            $csv->combine( map {"$_"} @{$value} );
            $value = $csv->string;

            # Warn if the type is wrong, but proceed anyway.
            $self->warn("Option \"$setting\" is unexpectedly an array")
                if ($types->{$setting} || '') ne 'ARRAY';
        }
        elsif ( ref $value eq 'HASH' )
        {
            # Just stringify. Deep structure will be silently lost.
            $csv->combine( map {"$_=$value->{$_}"} keys %{$value} );
            $value = $csv->string;

            # Warn if the type is wrong, but proceed anyway.
            $self->warn("Option \"$setting\" is unexpectedly a hash")
                if ($types->{$setting} || '') ne 'HASH';
        }
        else
        {
            # Just stringify. We know this is wrong, but the user
            # shouldn't be using an INI file for structured data.
            $value = "$value";

            # Don't know what to do; can't do anything about it.
            $self->warn("Option \"$setting\" will be corrupt in config file");
        }

        $settings->{default}{$setting} = $value;
    }

    # Write settings to the file.
    Config::INI::Writer->write_file($settings, $file);

    return 1;
}

# Write the current settings to an XML file.
sub _write_rcfile_xml
{
    my ($self, $file) = @_;

    # Installing a XML module is optional.
    eval 'use XML::Simple';
    $self->die('Can\'t write rcfile: XML::Simple is not installed.')
        if $EVAL_ERROR;

    open my $RCFILE, '>', $file
        or $self->die("Couldn't open file \"$file\": $OS_ERROR");
    print {$RCFILE} XMLout($self->get_options_as_defaults)
        or $self->die("Couldn't write to file \"$file\": $OS_ERROR");
    close $RCFILE
        or $self->die("Couldn't close file \"$file\": $OS_ERROR");

    return 1;
}

# Write the current settings to a JSON file.
sub _write_rcfile_json
{
    my ($self, $file) = @_;

    # Installing a JSON module is optional.
    eval 'use JSON::Any';
    $self->die('Can\'t write rcfile: JSON::Any is not installed.')
        if $EVAL_ERROR;

    my $json = JSON::Any->new;

    open my $RCFILE, '>', $file
        or $self->die("Couldn't open file \"$file\": $OS_ERROR");
    print {$RCFILE} $json->encode($self->get_options_as_defaults)
        or $self->die("Couldn't write to file \"$file\": $OS_ERROR");
    close $RCFILE
        or $self->die("Couldn't close file \"$file\": $OS_ERROR");

    return 1;
}

# Write the current settings to a YAML file.
sub _write_rcfile_yaml
{
    my ($self, $file) = @_;

    # Installing a YAML module is optional.
    eval 'use YAML::Any qw{DumpFile}';
    $self->die('Can\'t write rcfile: YAML::Any is not installed.')
        if $EVAL_ERROR;

    DumpFile( $file, $self->get_options_as_defaults );

    return 1;
}

# Write the current settings to a Perl file.
sub _write_rcfile_perl
{
    my ($self, $file) = @_;

    local $Data::Dumper::Terse = 1;

    open my $RCFILE, '>', $file
        or $self->die("Couldn't open file \"$file\": $OS_ERROR");
    print {$RCFILE} Dumper( $self->get_options_as_defaults )
        or $self->die("Couldn't write to file \"$file\": $OS_ERROR");
    close $RCFILE
        or $self->die("Couldn't close file \"$file\": $OS_ERROR");

    return 1;
}

1; # End of CLI::Startup

__END__
=head1 NAME

CLI::Startup - Simple initialization for command-line scripts

=head1 VERSION

Version 0.11

=head1 SYNOPSIS

C<CLI::Startup> can export a single method, C<startup()>, into the
caller's namespace. It transparently handles config files, defaults,
and command-line options.

  use CLI::Startup 'startup';

  # Returns the merged results of defaults, config file
  # and command-line options.
  my $options = startup({
    'opt1=s' => 'Option taking a string',
    'opt2:i' => 'Optional option taking an integer',
    ...
  });

It also supports an object-oriented interface with much more scope
for customization. The basic usage looks like this:

  use CLI::Startup;

  # Parse command line and read config
  $app = CLI::Startup->new({
      usage            => '[options] [other args ...]', # Optional
      options          => $optspec,
      default_settings => $defaults,
  });
  $app->init;

  # Combined command line, config file and default options. Almost
  # always what you want.
  $opts = $app->get_options;

  # Information about the current invocation of the calling script:
  $opts = $app->get_raw_options;       # Actual command-line options
  $conf = $app->get_config;            # Options set in config file
  $dflt = $app->get_default_settings;  # Wired-in script defaults

Most scripts can then use C<$opts> for all their customization needs.

You can also hide extra data in the config file, and access it
through C<$app->get_config>. The app settings will be stored in
a section of the config file named "default," so the rest of the
file is yours to do with as you wish. See the example implemetation
of an C<rsync> wrapper, below, for one use of this.

=head1 DESCRIPTION

Good command-line scripts always support command-line options using
Getopt::Long, and I<should> support default configuration in a file
in a standard format like YAML, JSON, XML, INI, etc. At minimum
it should include a C<--help> option that explains the other
options. Supporting all this takes quite a bit of boilerplate code.
In my experience, doing it right takes several hundred lines of
code that are practically the same in every script.

C<CLI::Startup> is intended to factor away almost all of that
boilerplate.  In the common case, all that's needed is a single
hashref listing the options (using C<Getopt::Long> syntax) as keys,
and a bit of help text as values. C<CLI::Startup> will automatically
generate the command-line parsing, reading of an optional config
file, merging of the two, and creation of a hash of the actual
settings to be used for the current invocation. It automatically
prints a usage message when it sees invalid options or the C<--help>
option. It automatically supports an option to save the current
settings in an rc file. It supports a C<--version> option that
prints C<$::VERSION> from the calling script, and a C<--manpage>
option that prints the formatted POD, if any, in the calling script.
All the grunt work is handled for you.

Any of these auto-generated options, except C<--help>, can be
disabled by including the option's name in the hashref with
a false value in place of the help text.

An additional hashref can be passed with default values for the
various options.

C<CLI::Startup> slightly enhances C<Getopt::Long> behavior by
allowing repeatable options to be specified I<either> with multiple
options I<or> with a commalist honoring CSV quoting conventions.
It also enhances INI file parsing to support hash-valued options
of the form:

    [default]
    hash=a=1, b=2, c=3

For convenience, C<CLI::Support> also supplies C<die()> and C<warn()>
methods that prepend the name of the script and postpend a newline.

    use CLI::Startup;

    my $app = CLI::Startup->new({
        'infile=s'   => 'An option for specifying an input file',
        'outfile=s'  => 'An option for specifying an output file',
        'password=s' => 'A password to use for something',
        'email=s@'   => 'Some email addresses to notify of something',
        'map=s%'     => 'Some name/value pairs mapping something to something',
        'x|y=i'      => 'Integer --x, could also be called --y',
        'verbose'    => 'Verbose output flag',
        'lines:i'    => 'Optional - the number of lines to process',
        'retries:5'  => 'Optional - number of retries; defaults to 5',
        ...
    });

    # Process the command line and resource file (if any)
    $app->init;

    # Information about the current invocation of the calling
    # script:
    my $opts = $app->get_raw_options;       # Actual command-line options
    my $conf = $app->get_config;            # Options set in config file
    my $dflt = $app->get_default_settings;  # Wired-in script defaults

    # Get the applicable options for the current invocation of
    # the script by combining, in order of decreasing precedence:
    # the actual command-line options; the options set in the
    # config file; and any wired-in script defaults.
    my $opts = $app->get_options;

    # Print messages to the user, with helpful formatting
    $app->die_usage();      # Print a --help message and exit
    $app->print_manpage();  # Print the formatted POD for this script and exit
    $app->print_version();  # Print version information for the calling script
    $app->warn();           # Format warnings nicely
    $app->die();            # Die with a nicely-formatted message

=head1 EXAMPLES

The following is a complete implementation of a wrapper for C<rsync>.
Since C<rsync> doesn't support a config file, this wrapper provides
that feature in 33 lines of code (according to C<sloccount>). Fully
1/3 of the file is simply a list of the rsync command-line options
in the definition of C<$optspec>; the rest is just a small amount
of glue for invoking C<rsync> with the requested options.

  #!/usr/bin/perl

  use File::Rsync;
  use CLI::Startup;
  use List::Util qw{ reduce };
  use Hash::Merge qw{ merge };

  # All the rsync command-line options
  $optspec = {
      'archive!'     => 'Use archive mode--see manpage for rsync',
      ...
      'verbose+'     => 'Increase rsync verbosity',
  };

  # Default settings
  $defaults = {
      archive  => 1,
      compress => 1,
      rsh      => 'ssh',
  };

  # Parse command line and read config
  $app = CLI::Startup->new({
      usage            => '[options] [module ...]',
      options          => $optspec,
      default_settings => $defaults,
  });
  $app->init;

  # Now @ARGV is a list of INI-file groups: run rsync for
  # each one in turn.
  do {
      # Combine the following, in this order of precedence:
      # 1) The actual command-line options
      # 2) The INI-file group requested in $ARGV[0]
      # 3) The INI-file [default] group
      # 4) The wired-in app defaults

      $options = reduce { merge($a, $b) } (
          $app->get_raw_options,
          $config->{shift @ARGV} || {},
          $app->get_config->{default},
          $defaults,
      );

      my $rsync = File::Rsync->new($options);

      $rsync->exec({
          src    => delete $options->{src},
          dest   => delete $options->{dest},
      }) or $app->warn("Rsync failed for $source -> $dest: $OS_ERROR");

  } while @ARGV;

My personal version of the above script uses strict and warnings,
and includes a complete manpage in POD. The POD takes up 246 lines,
while the body of the script contains only 67 lines of code (again
according to C<sloccount>). In other words, 80% of the script is
documentation.

C<CLI::Startup> saved a ton of effort writing this, by abstracting
away the boilerplate code for making the script behave like a normal
command-line utility. It consists of approximately 425 lines of
code (C<sloccount> again), so the same script without C<CLI::Startup>
would have been more than seven times longer, and would either have
taken many extra hours to write, or else would lack the features
that this version supports.

=head1 EXPORT

If you really don't like object-oriented coding, or your needs are
super-simple, C<CLI::Startup> optionally exports a single sub:
C<startup()>.

=head2 startup

  use CLI::Startup 'startup';

  my $options = startup({
    'opt1=s' => 'Option taking a string',
    'opt2:i' => 'Optional option taking an integer',
    ...
  });

Process command-line options specified in the argument hashref.
The argument is passed to C<CLI::Startup->new>, so anything
valid there is valid here.

Scripts using this function automatically respond to to the C<--help>
option, or to invalid options, by printing a help message and
exiting. They can also write a config file and exit, or any of the
other default features provided by C<CLI::Startup>.

If it doesn't exit, it returns a hash (or hashref, depending on the
calling context) of the options supplied on the command line. It
also automatically checks for default options in a resource file
named C<$HOME/.SCRIPTNAMErc> and folds them into the returned hash.

If you want any fancy configuration, or you want to customize any
behaviors, then you need to use the object-oriented interface.

=head1 ACCESSORS

The following methods are available when the object-oriented
interface is used.

=head2 get_config

  $config = $app->get_config;

Returns the contents of the resource file as a hashref. This
attribute is read-only; it is set when the config file is read,
which happens when C<$app->init()> is called. The referece
returned by this sub is to a clone of the settings, so although
its contents can be modified, it will have no effect on the C<$app>
object.

It is a fatal error to call C<get_config()> before C<init()> is
called.

=head2 get_default_settings

  $defaults = $app->get_default_settings;

Returns default settings as a hashref. Default settings are applied
with lower precedence than the rcfile contents, which is in turn
applied with lower precedence than command-line options.

=head2 set_default_settings

  $app->set_default_settings(\%settings);

Set the default settings for the command-line options.

It is a fatal error to call C<set_default_settings()> after
calling C<init()>.

=head2 get_initialized

  $app->init unless $app->get_initialized();

Read-only flag indicating whether the app is initialized. This is
used internally; you probably shouldn't need it since you should
only be calling C<$app->init()> once, near the start of your script.

=head2 get_options

  my $options = $app->get_options;

Read-only: the command options for the current invocation of the
script. This includes the actual command-line options of the script,
or the defaults found in the config file, if any, or the wired-in
defaults from the script itself, in that order of precedence.

Usually, this information is all your script really cares about.
It doesn't care about C<$app->get_config> or C<$app->get_optspec>
or any other building blocks that were used to ultimately build
C<$app->get_options>.

It is a fatal error to call C<get_options()> before calling C<init()>.

=head2 get_optspec

  my $optspec = $app->get_optspec();

Returns the hash of command-line options. Keys are option specifications
in the C<Getopt::Long> syntax, and values are the short descriptions
to be printed in a usage summary. See C<set_optspec> for an example,
and see C<Getopt::Long> for the full syntax.

=head2 set_optspec

  $app->set_optspec({
    'file=s'  => 'File to read',    # Option with string argument
    'verbose' => 'Verbose output',  # Boolean option
    'tries=i' => 'Number of tries', # Option with integer argument
    ...
  });

Set the hash of command-line options. The keys use C<Getopt::Long>
syntax, and the values are descriptions for printing in the usage
message.

It is a fatal error to call C<set_optspec()> after calling C<init()>.

=head2 get_raw_options

  $options = $app->get_raw_options;

Returns the options actually supplied on the command line--i.e.,
without adding in any defaults from the rcfile. Useful for checking
which settings were actually requested, in cases where one option
on the command line disables multiple options from the config file.

=head2 get_rcfile

  my $path = $app->get_rcfile;

Get the full path of the rcfile to read or write.

=head2 set_rcfile

  $app->set_rcfile( $path_to_rcfile );

Set the path to the rcfile to read or write. This overrides the
built-in default of C<$HOME/.SCRIPTNAMErc>, but is in turn overridden
by the C<--rcfile> option supported automatically by C<CLI::Startup>.

It is a fatal error to call C<set_rcfile()> after calling C<init()>.

=head2 get_usage

  print "Usage: $0: " . $app->get_usage . "\n";

Returns the usage string printed as part of the C<--help> output.
Unlikely to be useful outside the module.

=head2 set_usage

  $app->set_usage("[options] FILE1 [FILE2 ...]");

Set a usage string for the script. Useful if the command options
are followed by positional parameters; otherwise a default usage
message is supplied automatically.

It is a fatal error to call C<set_usage()> after calling C<init()>.

=head2 set_write_rcfile

  $app->set_write_rcfile( \&rcfile_writing_sub );

  sub rcfile_writing_sub
  {
      ($app, $filename) = @_;
      $config_data      = $app->get_options_as_defaults;

      # Do stuff with $config_data, and write it to
      # $filename in the desired format.
  }

A code reference for writing out the rc file, in case the default
file formats aren't good enough. Setting this to C<undef> disables
the command-line options C<--write-rcfile> and C<--rcfile-format>.
Those options are also disabled if I<reading> rc files is disabled
by setting the C<rcfile> attribute to anything that evaluates to
false.

For now, your writer will have to write in one of the formats
supported by C<CLI::Startup>, so this feature is mostly useful
for providing prettier output, with things like nice formatting
and helpful explanatory comments.

It is a fatal error to call C<set_write_rcfile()> after calling
C<init()>.

=head1 SUBROUTINES/METHODS

=head2 new

  # Normal: accept defaults and specify only options
  my $app = CLI::Startup->new( \%options );

  # Advanced: override some CLI::Startup defaults
  my $app = CLI::Startup->new({
    rcfile       => $rcfile_path, # Set to false to disable rc files
    write_rcfile => \&write_sub,  # Set to false to disable writing
    options      => \%options,
    defaults     => \%defaults,
  });

Create a new C<CLI::Startup> object to process the options defined
in C<\%options>. Options not specified on the command line or in a
config file will be set to the value contained in C<\%defaults>,
if any.

Setting the C<rcfile> option to a false value disables the C<--rcfile>
option, which in turn prevents the script from reading config files.

Setting the C<write_rcfile> option to a false value disables writing
config files with the C<--write-rcfile> option, but does not disable
reading config files created some other way.

=head2 BUILD

An internal method called by C<new()>.

=head2 init

  $app  = CLI::Startup->new( \%optspec );
  $app->init;
  $opts = $app->get_options;

Initialize command options by parsing the command line and merging
in defaults from the rcfile, if any. This is where most of the work
gets done. If you don't have any special needs, and want to use the
Perl fourish interface, the C<startup()> function basically does
nothing more than the example code above.

After C<init()> is called, most of the write accessors will throw
a fatal exception. It's not quite true that this object becomes
read-only, but you can think of it that way: the object has done
its heavy lifting, and now exists mostly to answer questions about
the app's configuration.

=head2 warn

  $app->warn("warning message");
  # Prints the following, for script "$BINDIR/foo":
  # foo: WARNING: warning message

Print a nicely-formatted warning message, identifying the script
by name. Identical to calling C<CORE::warn>, except for the formatting.

=head2 die

  $app->die("die message");
  # Prints the following, for script "$BINDIR/foo":
  # foo: FATAL: die message

Die with a nicely-formatted message, identifying the script that
died. This is exactly the same as calling C<CORE::die>, except
for the standardized formatting of the message. It also suppresses
any backtrace, by postpending a newline to your message.

=head2 die_usage

  $app->die_usage if $something_wrong;

Print a help message and exit. This is called internally if the
user supplies a C<--help> option on the command-line.

=head2 print_manpage

  $app->print_manpage;

Prints the formatted POD contained in the calling script.
If there's no POD content in the file, then the C<--help>
usage is printed instead.

=head2 print_version

  $app->print_version;

Prints the version of the calling script, if the variable C<$VERSION> is
defined in the top-level scope.

=head2 write_rcfile

  $app->write_rcfile();      # Overwrite the rc file for this script
  $app->write_rcfile($path); # Write an rc file to a new location

Write the current settings for this script to an rcfile--by default,
the rcfile read for this script, but optionally a different file
specified by the caller. The automatic C<--write-rcfile> option
always writes to the script specified in the C<--rcfile> option.

The file format can be specified by the C<--rcfile-format> option,
and must be one of: ini, yaml, json, xml, and perl. By default this
method will attempt to use .ini file format, because it's the
simplest and most readable for most option specification needs. If
the module C<Config::INI::Writer> isn't installed, it will fall back
on perl format, which looks like the output of C<Data::Dumper>.

The prettiest formats are ini, yaml, and perl. The others will tend
to be harder to read.

The simplest format for users is ini. It's good enough, if you
don't have complicated command-line options, or additional data
hidden in your config files.

The most powerful formats are json and yaml, of which yaml is the
most readable. It will let you put pretty much any data structure
you desire in your config files.

It's a fatal error to call C<write_rcfile()> before calling C<init()>.

=head2 get_options_as_defaults

    $options = $app->get_options_as_defaults;

Returns the same hashref as C<$app->get_config> would do, except
that C<$options->{default}> is overridden with the current settings
of the app. This is a helper method if you write a function to write
config files in some format not natively supported by C<CLI::Startup>.
It lets you freeze the state of the current command line as the
default for future runs.

This sub will also strip out any of the auto-generated options, like
C<--help> and C<--rcfile>, since they don't belong in a config file.

=head1 AUTHOR

Len Budney, C<< <len.budney at gmail.com> >>

=head1 BUGS AND LIMITATIONS

C<CLI::Startup> tries reasonably to keep things consistent, but it
doesn't stop you from shooting yourself in the foot if you try at
all hard. For example, it doesn't confirm that your default options
actually correspond to your option specifications: it will ignore
defaults for nonexistent options, and cheerfully let you assign a
hashref as the default value of a boolean option, etc.

Please report any bugs or feature requests to C<bug-cli-startup at
rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=CLI-Startup>.  I
will be notified, and then you'll automatically be notified of
progress on your bug as I make changes.


=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc CLI::Startup

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=CLI-Startup>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/CLI-Startup>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/CLI-Startup>

=item * Search CPAN

L<http://search.cpan.org/dist/CLI-Startup/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2011 Len Budney.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

