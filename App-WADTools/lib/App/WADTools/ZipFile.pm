##########################
# App::WADTools::ZipFile #
##########################
package App::WADTools::ZipFile;

=head1 NAME

App::WADTools::ZipFile

=head1 SYNOPSIS

 my $zip = Archive::WADTools::ZipFile->new( file => $zipfile );
 my $zip_members = $zip->get_zip_members;
 print q(Zip members: ) . join(q(, ), @{$zip_members});
 $zip->extract_members(files => $zip_members, $tempdir => q(/tmp));

=head1 DESCRIPTION

This object manages files compressed in C<.zip> format.  This object can
provide a listing of the contents of a zip file, as well as obtain checksums
of the zipfile.  This object inherits methods and attributes from
L<App::WADTools::Roles::File>; please see the documentation for that role for
more information on the methods/attributes it provides.

=cut

### System modules
# 'Moo' calls 'strictures', which is 'strict' + 'warnings'
use Moo;
use Archive::Zip qw(:ERROR_CODES);
use Log::Log4perl;

### Local modules
use App::WADTools::Error;
use App::WADTools::Timer;

### Roles
with qw(
    App::WADTools::Roles::File
    App::WADTools::Roles::Keysum
);

=head2 Attributes

=over

=item extract_files_time

The time required to extract all of the WAD files inside of a ZIP file.  This
attribute is set at the end of the L<extract_files()> method.

=cut

has q(extract_files_time) => (
    is => q(rw),
);

=item last_zip_error

The default behaivor of L<Archive::Zip> is to use the L<Carp> module to output
any error messages.  This module changes that behavior by telling
L<Archive::Zip> to call this module when there are any zip errors.  Once this
module recieves the error text, it stores the error into this attribute.

=cut

has q(last_zip_error) => (
    is => q(rw),
);

=item members

A reference to an array that contains the names of all of the files inside
this zip file.

=cut

has q(members) => (
    is      => q(rw),
    default => sub { [] },
);

=item _zip_obj

An internal attribute meant to store a reference to the L<Archive::Zip> object
that is created when this object is instantiated.  Use this attribute at your
own risk, it may change purpose without any notice.

=cut

has q(_zip_obj) => (
    is => q(rw),
    #isa
);

=back

=head2 Methods

=over

=item new(file => $zipfile) (aka BUILD)

Creates a L<App::WADTools::ZipFile> object with the file passed in as C<file>
in the constructor.  This method populates the zipfile's object attributes,
including MD5/SHA checksums.

Optional arguments:

=over

=item file

The full path to the C<*.zip> file that this object will work with.

=back

=cut

sub BUILD {
    my $self = shift;
    my $log = Log::Log4perl->get_logger(""); # "" = root logger

    my $zip = Archive::Zip->new();
    # see https://metacpan.org/pod/Archive::Zip#Zip-Archive-Utility-Methods
    # for more info on setting the error handler
    Archive::Zip::setErrorHandler(sub {$self->handle_zip_error(@_)});
    $log->debug(q(Reading file: ) . $self->filepath);

    # generate filehandle is called here, because the Role won't run a BUILD
    # method prior to this BUILD method being run
    $self->generate_filehandle();
    $self->generate_filedir_filename();
    if ( $zip->readFromFileHandle($self->filehandle) != AZ_OK ) {
        $log->error(q(Problem reading zip directory for: ) . $self->filepath);
        $log->error(q(Error message: ) . $self->last_zip_error);
        my $error = App::WADTools::Error->new(
            level   => q(fatal),
            id      => q(zipfile.read_zip_directory),
            message => qq(Can't read zip 'directory': ) . $self->filepath,
            raw     => $self->last_zip_error,
        );
        return $error;
    }
    # store a copy of the Archive::Zip object for other methods to use
    $self->_zip_obj($zip);
    $log->debug("Calling zip->members");
    my @member_objs = $zip->members();
    my @members;
    foreach my $member ( @member_objs ) {
        # push the filename of the zip member onto the @members array
        push(@members, $member->fileName);
    }
    # store the extracted member names inside this ZipFile object
    $self->members(\@members);
    return $self;
}

=item extract_files(files => \@files, tempdir => q(/tmp))

Extracts all of the files listed in the array reference C<@files> from the
zipfile into a temporary directory, and returns a scalar containing the path
to the temporary directory that the files were extracted into.

Required arguments:

=over

=item files

An array reference containing a list of files to extract from this zipfile.

=back


Optional arguments:

=over

=item tempdir

The full path to the temporary directory to use for extracting files.  If this
argument is not used, then the L<File::Temp> module will pick a directory
based on it's internal heuristics.

=back

=cut

sub extract_files {
    my $self = shift;
    my %args = @_;
    my $log = Log::Log4perl->get_logger(""); # "" = root logger

    my $zip = $self->_zip_obj;
    my $tempdir = $args{tempdir};

    my %file_temp_opts;

    # create a timer and start it
    my $timer = App::WADTools::Timer->new();
    $timer->start(name => q(extract_files));

    if ( defined $tempdir ) {
        %file_temp_opts = (
            DIR         => $tempdir,
            TEMPLATE    => qq(wadindex.XXXXXXXX),
        );
    } else {
        %file_temp_opts = (
            TMPDIR      => 1,
            TEMPLATE    => qq(wadindex.XXXXXXXX),
        );
    }
    my $dh = File::Temp->newdir(%file_temp_opts);

    $log->debug(qq(Created temp dir ) . $dh->dirname);
    foreach my $file ( @{$args{files}} ) {
        $log->debug(qq(- extracting: $file));
        my $temp_file = $dh->dirname . q(/) . $file;
        my $unzip_status = $zip->extractMemberWithoutPaths($file, $temp_file);
        if ( $unzip_status != AZ_OK ) {
            $log->error(qq(Could not unzip $file));
            $log->error(q(Error message from Archive::Zip;));
            $log->error($self->last_zip_error);
            my $error = App::WADTools::Error->new(
                level   => q(fatal),
                id      => q(zipfile.extract_member_without_paths),
                message => qq(Problem extracting member for: $file),
                raw     => $self->last_zip_error,
            );
            # stop the timer
            $timer->stop(name => q(extract_files));
            # calculate the time difference
            $self->extract_files_time(
                $timer->time_value_difference(name => q(extract_files))
            );
            # return the error object
            return $error;
        }
        $log->debug(q(- done extracting: ) . $file);
    }

    # stop the timer
    $timer->stop(name => q(extract_files));
    # calculate the time difference
    $self->extract_files_time(
        $timer->time_value_difference(name => q(extract_files))
    );

    return $dh;
}


=item get_zip_members( )

Returns an array containing all of the files contained inside of the zipfile.

=cut

sub get_zip_members {
    my $self = shift;
    my $log = Log::Log4perl->get_logger(""); # "" = root logger

    # cast into an array, callers are expecting an array of filepaths
    return @{$self->members};
}

=item handle_zip_error()

Handle any errors encountered by L<Archive::Zip>.  Sets the attribute
L<last_zip_error> with the text of the error passed in by L<Archive::Zip> when
called.

=cut

sub handle_zip_error {
    my $self = shift;
    my $error_msg = shift;
    my $log = Log::Log4perl->get_logger(""); # "" = root logger

    $log->debug(q(Received error message from Archive::Zip:));
    chomp($error_msg);
    $log->debug($error_msg);
    $self->last_zip_error($error_msg);
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

    perldoc App::WADTools::ZipFile

=head1 COPYRIGHT & LICENSE

Copyright (c) 2013-2014 Brian Manning, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

# fin!
# vim: set shiftwidth=4 tabstop=4
1;
