####################################
# package App::WADTools::idGamesDB #
####################################
package App::WADTools::idGamesDB;

=head1 NAME

App::WADTools::idGamesDB

=head1 SYNOPSIS

 my $db = App::WADTools::idGamesDB->new(filename => q(/path/to/file.db));
 # check that the database already has a schema applied to it
 my $result = $db->connect( check_schema => 1 );
 if ( ref($result) eq q(App::WADTools::Error) ) {
     # something bad happened
 }
 # returns a App::WADTools::File object
 $file = $idg_db->get_file_by_path(
     path     => q(/some/imaginary/path/),
     filename => q(bogusfile.zip),
 );

=head1 DESCRIPTION

Create/read/update/delete the database created by the script
C<idgames_db_dump>.

This object consumes the L<App::WADTools::Role::Database> role.  See the POD
for the role object for more information on methods/attributes it provides.

=cut

### System modules
use Log::Log4perl qw(get_logger :no_extra_logdie_message);
# 'Moo' calls 'strictures', which is 'strict' + 'warnings'
use Moo;
use Data::Dumper;
$Data::Dumper::Indent = 1;
$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Terse = 1;

### Roles
# contains App::WADTools::Error and App::WADTools::File
with q(App::WADTools::Roles::Database);

=head2 Methods

=over

=item add_file(file => $file)

Add an L<App::WADTools::File> object to the database.  Returns true C<1> if
the insert was successful, or an L<App::WADTools::Error> object if there was a
problem inserting the L<App::WADTools::File> object into the database.

Required arguments:

=over

=item file

The L<App::WADTools::File> object to add to the database.

=back

=cut

sub add_file {
    my $self = shift;
    my %args = @_;
    my $log = Log::Log4perl->get_logger(""); # "" = root logger

    # check for an existing database connection
    my $error = $self->is_connected;
    return $error if ( ref($error) eq q(App::WADTools::Error));
    my $dbh = $self->dbh;

    $log->logdie(q(Missing 'file' argument))
        unless(defined($args{file}));
    my $file = $args{file};
    $log->debug(sprintf(q(ID: %5u; ), $file->id)
            . qq(Adding to DB: ) . $file->filename);

    my $file_sql = <<'FILESQL';
        INSERT INTO files VALUES (
            ?, ?, ?, ?, ?,
            ?, ?, ?, ?, ?,
            ?, ?, ?, ?, ?,
            ?, ?, ?)
FILESQL

    ### INSERT FILE
    my $sth_file = $dbh->prepare($file_sql);
    if ( defined $dbh->err ) {
        $log->error(q('prepare' call to INSERT into 'files' failed));
        $log->error(q(Error message: ) . $dbh->errstr);
        $error = App::WADTools::Error->new(
            type    => q(database.file_insert.prepare),
            message => $dbh->errstr
        );
        return $error;
    }

    # bind params; bind params start counting at '1'
    my $bind_counter = 1;
    foreach my $block_name ( @{$file->attributes} ) {
        # catches 'url', 'idgamesurl' and 'reviews'
        next if ( $block_name =~ /url|reviews/ );
        #$log->debug(qq(Binding $block_name -> ) . $file->$block_name));
        $sth_file->bind_param($bind_counter, $file->$block_name);
        $bind_counter++;
    }
    #$log->debug(q(Executing 'INSERT' for file ID ) . $file->id);
    # $rv should be anything but 'undef' if the operation was successful
    my $rv = $sth_file->execute();
    if ( ! defined $rv ) {
        $log->error(q(INSERT for file ID ) . $file->id
            . q( returned an error: ) . $sth_file->errstr);
        my $error = App::WADTools::Error->new(
            type    => q(database.file_insert.execute),
            message => $sth_file->errstr
        );
        return $error;
    } else {
        $log->debug(sprintf(q(ID: %5u; ), $file->id)
            . qq(Successful INSERT of 'file' record));
    }

    ### INSERT VOTES
    my $vote_sql = q|INSERT INTO votes VALUES (?, ?, ?, ?)|;
    my $sth_vote = $dbh->prepare($vote_sql);
    if ( defined $dbh->err ) {
        $log->error(q('prepare' call to INSERT into 'votes' failed));
        $log->error(q(Error message: ) . $dbh->errstr);
        my $error = App::WADTools::Error->new(
            type    => q(database.vote_insert.prepare),
            message => $dbh->errstr
        );
        return $error;
    }
    my $vote_id = 0;
    my @reviews;
    # if there's no reviews, then $file->reviews will be 'undef'
    if ( defined $file->reviews ) {
        @reviews = @{$file->reviews};
    }
    foreach my $vote ( @reviews ) {
        # increment $vote_id
        $vote_id++;
        $sth_vote->bind_param(1, $vote_id);
        $sth_vote->bind_param(2, $file->id);
        $sth_vote->bind_param(3, $vote->text);
        $sth_vote->bind_param(4, $vote->vote);
        #$log->debug(q(Executing 'INSERT' for file ID/vote ID )
        #    . $file->id . q(/) . $vote_id);
        $rv = $sth_vote->execute();
        # $rv should be anything but 'undef' if the operation was successful
        if ( ! defined $rv ) {
            $log->error(q(INSERT for file ID ) . $file->id
                . q( returned an error: ) . $sth_file->errstr);
            my $error = App::WADTools::Error->new(
                type    => q(database.vote_insert.execute),
                message => $sth_file->errstr
            );
            return $error;
        } # else {
        #    $log->debug(q('INSERT' of vote for file ID/vote ID )
        #        . $file->id . q(/) . $vote_id . qq( successful));
        #}
    }
    if ( $vote_id > 0 ) {
        $log->debug(sprintf(q(ID: %5u; ), $file->id)
            . qq|Successful INSERT of $vote_id vote(s)|);
    } else {
        $log->debug(sprintf(q(ID: %5u; ), $file->id)
            . q|No votes to INSERT into database|);
    }

    # return 'true'
    return 1;
}

=item get_file_by_id()

Queries the database for a L<App::WADTools::File> object in the database with
the ID passed in as the argument.  Returns a L<App::WADTools::File> object if
the file ID was found in the database, or an L<App::WADTools::Error> object
with the C<error_type> of C<file_id_not_found>.

Required arguments:

=over

=item id

An integer value that represents a file ID in the idGames Archive.

=back

=cut

sub get_file_by_id {
    my $self = shift;
    my %args = @_;
    my $log = Log::Log4perl->get_logger(""); # "" = root logger

    # check for an existing database connection
    my $error = $self->is_connected;
    return $error if ( ref($error) eq q(App::WADTools::Error));
    my $dbh = $self->dbh;

    $log->logdie(q(Missing 'id' parameter))
        unless ( defined $args{id} );
    my $file_id = $args{id};

    my $sql = q(SELECT * FROM files WHERE id = ?);
    $log->debug(q(Prepare: querying for file from file ID));
    $log->debug(qq(Prepare: SQL: $sql));

    # prepare the SQL
    my $sth = $dbh->prepare($sql);
    if ( defined $dbh->err ) {
        $log->warn(q(Preparing query for file failed));
        $log->warn(q(Error message: ) . $dbh->errstr);
        my $error = App::WADTools::Error->new(
            type    => q(database.get_file_by_id.prepare),
            message => $dbh->errstr
        );
        return $error;
    }

    # bind params
    $log->debug(qq(Binding query params; 1: $file_id));
    $sth->bind_param(1, $file_id);

    # execute the SQL
    $log->debug(q(Calling $sth->execute));
    $sth->execute;
    if ( defined $sth->err ) {
        $log->warn(q(Executing query for file failed));
        $log->warn(q(Error message: ) . $sth->errstr);
        my $error = App::WADTools::Error->new(
            type    => q(database.get_file_by_id.execute),
            message => $dbh->errstr
        );
        return $error;
    }

    $log->debug(q(Retrieving row via fetchrow_arrayref));
    my $row = $sth->fetchrow_arrayref;
    # return $row as an undefined value if there are no rows returned from the
    # database query
    return $row unless ( defined $row );
    #$log->debug(q(dump: ) . Dumper $row);
    my $file = $self->unserialize_file(db_row => $row);
    $log->debug(qq(File ID ) . $file->id . q( has path: )
        . $file->dir . q(/) . $file->filename);
    return $file;
}

=item get_file_by_path()

Queries the database for a L<App::WADTools::File> object in the database that
matches the C<$path/$filename> arguments passed in.  A valid file path is the
path from the root of the idGames Archive file tree, i.e. the directory
containing the folders C<combos>, C<deathmatch>, C<historic>, C<idstuff>, etc.
Returns a L<App::WADTools::File> object if the file was found in the database,
or an L<App::WADTools::Error> object with the error C<type> of
C<file_not_found>.

Required arguments:

=over

=item path

The path to the file from the root of the C<idGames Archive>.

=item filename

The filename of the file in C<idGames Archive>.

=back

=cut

sub get_file_by_path  {
    my $self = shift;
    my %args = @_;
    my $log = Log::Log4perl->get_logger(""); # "" = root logger

    # check for an existing database connection
    my $error = $self->is_connected;
    return $error if ( ref($error) eq q(App::WADTools::Error));
    my $dbh = $self->dbh;

    $log->logdie(q(Missing 'path' parameter))
        unless ( defined $args{path} );
    $log->logdie(q(Missing 'filename' parameter))
        unless ( defined $args{filename} );

    my $path = $args{path};
    my $filename = $args{filename};
    my $sql = q(SELECT * FROM files WHERE dir = ? AND filename = ?);
    $log->debug(q(Prepare: querying for file ID from dir/filename));
    $log->debug(qq(Prepare: SQL: $sql));

    # prepare the SQL
    my $sth = $dbh->prepare($sql);
    if ( defined $dbh->err ) {
        $log->warn(q(Preparing query for file failed));
        $log->warn(q(Error message: ) . $dbh->errstr);
        my $error = App::WADTools::Error->new(
            type    => q(database.get_file_by_path.prepare),
            message => $dbh->errstr
        );
        return $error;
    }

    # bind params
    $log->debug(qq(Binding query params; 1: $path, 2: $filename));
    $sth->bind_param(1, $path);
    $sth->bind_param(2, $filename);

    # execute the SQL
    $log->debug(q(Calling $sth->execute));
    $sth->execute;
    if ( defined $sth->err ) {
        $log->warn(q(Executing query for file failed));
        $log->warn(q(Error message: ) . $sth->errstr);
        my $error = App::WADTools::Error->new(
            type    => q(database.get_file_by_path.execute),
            message => $dbh->errstr
        );
        return $error;
    }

    $log->debug(q(Retrieving row via fetchrow_arrayref));
    my $row = $sth->fetchrow_arrayref;
    # return $row as an undefined value if there are no rows returned from the
    # database query
    return $row unless ( defined $row );
    #$log->debug(q(dump: ) . Dumper $row);
    my $file = $self->unserialize_file(db_row => $row);
    $log->debug(qq(File ID for ) . $file->dir . q(/) . $file->filename
        . q( is ) . $file->id);
    return $file;
}

=item unserialize_file(db_row => $row)

Accepts a row from a database query of the C<files> table, and unserializes
the file object into a L<App::WADTools::File> object.   Returns the
unserialized C<File> object if there were no errors, or an
L<App::WADTools::Error> object if there was an error.

Required arguments:

=over

=item db_row

The row from a query of the C<files> table, obtained with a call to
C<$sth-E<gt>fetchrow_arrayref()> from a L<DBI> database handle.

=back

=cut

sub unserialize_file {
    my $self = shift;
    my %args = @_;
    my $log = Log::Log4perl->get_logger(""); # "" = root logger

    $log->logdie(q(Missing 'db_row' parameter))
        unless ( exists $args{db_row} );

    my $db_row = $args{db_row};
    my @row = @{$db_row};
    # create the $file object that will be returned after it is unserialized
    my $file = App::WADTools::File->new();
    # bind params; bind params start counting at '1'
    my $column = 0;
    foreach my $key ( @{$file->attributes} ) {
        # skip the 'url', 'idgamesurl' and 'reviews' fields
        next if ( $key =~ /url|reviews/ );
        #$log->debug(qq(Unserializing: '$key' -> ') . $row[$column] . q('));
        # $file->{$key} needs the curly braces
        $file->{$key} = $row[$column];
        # go to the next column in the row array
        $column++;
    }
    return $file;
}

=back

=head1 AUTHOR

Brian Manning, C<< <brian at xaoc dot org> >>

=head1 BUGS

Please report any bugs or feature requests to the GitHub issue tracker for
this project:

C<< <https://github.com/spicyjack/wadtools/issues> >>.

=head1 SUPPORT

You can find documentation for this script with the perldoc command.

    perldoc App::WADTools::idGamesDB

=head1 COPYRIGHT & LICENSE

Copyright (c) 2013 Brian Manning, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;