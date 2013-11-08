#######################################
# package App::idgasmDBTools::INIFile #
#######################################
package App::idgasmDBTools::INIFile;
use Config::Std;
use Digest::MD5;
use Log::Log4perl qw(get_logger :no_extra_logdie_message);
use Moo;
use Data::Dumper;
$Data::Dumper::Indent = 1;
$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Terse = 1;

=head1 App::idgasmDBTools::INIFile

INIFileure/manage script options using L<Getopt::Long>.

=head2 Attributes

=over

=item filename

A filename to the C<INI> file that should be parsed.

=back

=cut

has filename => (
    is  => q(rw),
    isa => sub {
                my $self = shift;
                die "$self is not a valid filename"
                    unless (-r $self)
            },

);

=head2 Methods

=over

=item new()

Creates the L<App::idgasmDBTools::INIFile> object.  Method is automatically
provided by the L<Moo> module as the C<BUILD> method.

Required arguments:

=over

=item filename

The filename of the C<INI> file to read from and possibly write to.

=back

=item md5_checksum()

Generates an C<MD5> checksum for each database transaction in the C<INI> file,
and appends the checksum to the C<INI> checksum field for that transaction.
Returns a reference to a L<Config::Std> hash updated with checksums.

Required arguments:

=over

=item db_schema

A scalar reference to the database schema hash read in from the C<INI> file.

=back

=cut

sub md5_checksum {
    my $self = shift;
    my %args = @_;
    my $log = Log::Log4perl->get_logger("");

    $log->logdie(q(Missing 'db_schema' argument))
        unless(defined($args{db_schema}));

    my $db_schema = $args{db_schema};
    # go through each field in each record of the INI file, and build a scalar
    # that combines all of the fields so a checksum can be generated against
    # the combined fields
    my $digest = Digest::MD5->new();
    my $data;
    foreach my $block_id ( sort(keys(%{$db_schema})) ) {
        $log->debug(qq(Parsing schema block: $block_id));
        my %block = %{$db_schema->{$block_id}};
        foreach my $block_key ( qw( description notes sql ) ){
            #$log->debug(qq(  $block_key: ) . $block{$block_key});
            $data .= $block{$block_key};
        }
        $log->debug(q(Combined fields are ) . length($data)
            . q| byte(s) in size|);
        $digest->add($data);
        my $checksum = $digest->b64digest;
        $log->debug(qq(Checksum: $checksum));
        $block{checksum} = $checksum;
        $db_schema->{$block_id} = \%block;
    }
    return $db_schema;
}

=item read_ini_config()

Reads the INI file specified by the C<filename> attribute, and returns a
reference to the hash data structure set up by C<Config::Std>.

=cut

sub read_ini_config {
    my $self = shift;
    my $log = Log::Log4perl->get_logger("");

    my $db_schema;
    $log->debug(q(Reading INI file ) . $self->filename);
    if ( -r $self->filename ) {
        read_config($self->filename => $db_schema);
        my @transactions = keys(%{$db_schema});
        $log->debug(qq(Database transaction keys are: ));
        $log->debug(q(-> ) . join(qq(, ), sort(@transactions)));
        #$self->db_schema($db_schema);
        return $db_schema;
    } else {
        $log->logdie(q(Can't read INI file!));
    }
}

=item write_ini_config()

Writes the C<INI> file, to the same filename that was used when this object
was created, unless optional argument C<filename> below is used.

Required arguments:

=over

=item db_schema

The database schema hash object created by L<Config::Std> to write out to
disk.

=back

Optional arguments:

=over

=item filename

If a C<filename> argument is passed in, write C<INI> config to that filename
(if possible).

=back

=cut

sub write_ini_config {
    my $self = shift;
    my %args = @_;
    my $log = Log::Log4perl->get_logger("");

    $log->logdie(q(Missing 'db_schema' argument))
        unless(defined($args{db_schema}));
    my $db_schema = $args{db_schema};
    #$self->dump_schema(
    #    db_schema => $db_schema
    #    extra_text => q(write_ini_config),
    #);

    my $write_filename = $self->filename;
    if ( defined $args{filename} ) {
        $write_filename = $args{filename};
    }

    $log->debug(q(Writing INI file ) . $write_filename);
    if ( -w $write_filename ) {
        eval { write_config($db_schema => $write_filename); };
        if ( $@ ) {
            $log->logdie(qq(Error writing INI file: $@));
        }
    } else {
        $log->logdie(q(Can't write INI file!));
    }
}

=item dump_schema()

Dumps the database schema hash passed in by the caller to C<$log-E<gt>debug>.

Optional arguments:

=over

=item extra_text

Extra text that will be printed along with the database schema dump

=back

=cut

sub dump_schema {
    my $self = shift;
    my %args = @_;
    my $log = Log::Log4perl->get_logger("");

    $log->logdie(q(Missing 'db_schema' argument))
        unless(defined($args{db_schema}));

    my $db_schema = $args{db_schema};
    $log->debug(q(Database schema dump...));
    if ( defined $args{extra_text} ) {
        $log->debug($args{extra_text});
    }

    $log->debug(
        qq(==== Database Schema Dump Begins ====\n)
        . Dumper($db_schema)
        . q(==== Database Schema Dump Ends ====)
    );
}

=back

=cut

1;
