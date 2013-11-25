#!/usr/bin/perl -w

# Copyright (c) 2013 by Brian Manning <brian at xaoc dot org>

# For support with this file, please file an issue on the GitHub issue tracker
# for this project: https://github.com/spicyjack/idgasm-tools/issues

=head1 NAME

B<idgames_file_map.pl> - Build a mapping of filenames to file ID's from the
files stored in C<idGames Archive>.

=head1 VERSION

Version 0.002

=cut

our $VERSION = '0.002';

=head1 SYNOPSIS

 perl idgames_file_map.pl [OPTIONS]

 Script options:
 -h|--help          Shows this help text
 -d|--debug         Debug script execution
 -v|--verbose       Verbose script execution

 Other script options:
 -o|--output        Output file to write to; default is STDOUT
 -x|--xml           Request XML data from idGames API (default)
 -j|--json          Request JSON data from idGames API
 -w|--overwrite     Overwrite a file that is used as --output

 Misc. script options:
 -c|--colorize      Always colorize script output
 --no-random-wait   Don't use random pauses between GET requests
 --random-wait-time Seed for random wait timer; default = 5, 0-5 seconds
 --debug-noexit     Don't exit script when --debug is used
 --debug-requests   Exit after this many requests when --debug is used
 --no-die-on-error  Don't exit when too many HTTP errors are generated
 --start-at         Start at this file ID, instead of file ID '1'

 Example usage:

 # build a mapping of file IDs to file paths from idGames API
 idgames_file_map --output /path/to/output.txt

 # Debug, start at request ID 1242, make only 5 requests
 idgames_file_map --debug --start-at 1242 --debug-requests 5

You can view the full C<POD> documentation of this file by calling C<perldoc
idgames_file_map.pl>.

=cut

our @options = (
    # script options
    q(debug|d),
    q(verbose|v),
    q(help|h),
    q(colorize|c), # always colorize output

    # other options
    q(output|o=s),
    q(json|j),
    q(xml|x),
    q(overwrite|w),
    q(random-wait!),
    q(random-wait-time=i),
    q(debug-noexit),
    q(debug-requests=i),
    q(die-on-error!),
    q(start-at=i),
);

=head1 DESCRIPTION

B<idgames_file_map.pl> - Build a mapping of filenames to file ID's from the
files stored in C<idGames Archive>.

=cut

################
# package main #
################
package main;

# pragmas
use 5.010;
# https://metacpan.org/pod/strictures
use strictures 1;
use utf8;

# system packages
use Carp;
use Config::Std;
use File::Basename;
use HTTP::Status;
use Log::Log4perl qw(get_logger :no_extra_logdie_message);
use Log::Log4perl::Level;
use LWP::UserAgent;
use Pod::Usage;

# Data::Dumper gets it's own block, cause it has extra baggage
use Data::Dumper;
$Data::Dumper::Indent = 1;
$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Terse = 1;

# local packages
use App::idgasmTools::Config;
use App::idgasmTools::File;
use App::idgasmTools::JSONParser;
use App::idgasmTools::XMLParser;

# script constants
use constant {
    DELAY_TIME => 5,
    DEBUG_REQUESTS => 100,
};

    # total number of API requests
    my $my_name = basename($0);
    my $total_requests = 0;
    binmode(STDOUT, ":utf8");

    # create a logger object
    my $cfg = App::idgasmTools::Config->new(options => \@options);
    # What kind of data are we requesting and parsing? JSON or XML?
    my $parse_type;
    if ( $cfg->defined(q(json)) ) {
        $parse_type = q(json);
    } else {
        $parse_type = q(xml);
    }

    # dump and bail if we get called with --help
    if ( $cfg->defined(q(help)) ) { pod2usage(-exitstatus => 1); }

    # Start setting up the Log::Log4perl object
    my $log4perl_conf = qq(log4perl.rootLogger = WARN, Screen\n);
    if ( $cfg->defined(q(verbose)) && $cfg->defined(q(debug)) ) {
        die(q(Script called with --debug and --verbose; choose one!));
    } elsif ( $cfg->defined(q(debug)) ) {
        $log4perl_conf = qq(log4perl.rootLogger = DEBUG, Screen\n);
    } elsif ( $cfg->defined(q(verbose)) ) {
        $log4perl_conf = qq(log4perl.rootLogger = INFO, Screen\n);
    }

    # Use color when outputting directly to a terminal, or when --colorize was
    # used
    if ( -t STDOUT || $cfg->get(q(colorize)) ) {
        $log4perl_conf .= q(log4perl.appender.Screen )
            . qq(= Log::Log4perl::Appender::ScreenColoredLevels\n);
    } else {
        $log4perl_conf .= q(log4perl.appender.Screen )
            . qq(= Log::Log4perl::Appender::Screen\n);
    }

    $log4perl_conf .= qq(log4perl.appender.Screen.stderr = 1\n)
        . qq(log4perl.appender.Screen.utf8 = 1\n)
        . qq(log4perl.appender.Screen.layout = PatternLayout\n)
        . q(log4perl.appender.Screen.layout.ConversionPattern )
        # %r: number of milliseconds elapsed since program start
        # %p{1}: first letter of event priority
        # %4L: line number where log statement was used, four numbers wide
        # %M{1}: Name of the method name where logging request was issued
        # %m: message
        # %n: newline
        . qq|= [%8r] %p{1} %4L (%M{1}) %m%n\n|;
        #. qq( = %d %p %m%n\n)
        #. qq(= %d{HH.mm.ss} %p -> %m%n\n);

    # create a logger object, and prime the logfile for this session
    Log::Log4perl::init( \$log4perl_conf );
    my $log = get_logger("");

    my $debug_requests = DEBUG_REQUESTS;
    if ( $log->is_debug && $cfg->defined(q(debug-requests)) ) {
        $debug_requests = $cfg->get(q(debug-requests));
        $log->debug(qq(Setting number of API requests to $debug_requests));
    }

    # check that we're not overwriting files if --output is used
    if ( $cfg->defined(q(output)) ) {
        $log->logdie(qq(Won't overwrite file) . $cfg->get(q(output))
            . q( without '­-overwrite' option))
            if ( -e $cfg->get(q(output)) && ! $cfg->defined(q(overwrite)) );
    }

    # print a nice banner
    $log->info(qq(Starting $my_name, version $VERSION));
    $log->info(qq(My PID is $$));

    # start at file ID 1, keep going until you get a "error" response instead
    # of a "content" response in the JSON
    # Note: file ID '0' is invalid
    my $file_id = 1;
    # unless '--start-at' is used, then start at that file ID
    if ( $cfg->defined(q(start-at)) ) {
        $file_id = $cfg->get(q(start-at));
        $log->debug(qq(Starting at file ID $file_id));
    }
    my $request_errors = 0;
    my $random_wait_delay = DELAY_TIME;
    if ( $cfg->defined(q(random-wait-time)) ) {
        $random_wait_delay = $cfg->get(q(random-wait-time));
        $log->debug(qq(Using $random_wait_delay for ѕeed for random delay));
    }
    my %file_map;
    my $ua = LWP::UserAgent->new(agent => qq($my_name $VERSION));
    my $idgames_url = q(http://www.doomworld.com/idgames/api/api.php?);
    $idgames_url .= q(action=get&);

    # set up the parser
    my $parser;
    if ( $parse_type eq q(json) ) {
        # don't append 'out=json' to URL unless --json was used
        $idgames_url .= q(out=json&);
        $parser = App::idgasmTools::JSONParser->new();
        $log->debug(qq(Using JSON API calls to idGames Archive API));
    } else {
        $parser = App::idgasmTools::XMLParser->new();
        $log->debug(qq(Using XML API calls to idGames Archive API));
    }

    # Loop across all of the file IDs, until a request for a file ID returns
    # an error of some kind
    HTTP_REQUEST: while (1) {
        my $random_wait = int(rand($random_wait_delay));
        my $fetch_url =  $idgames_url . qq(id=$file_id);
        $log->debug(qq(Fetching $fetch_url));
        # POST requests; https://metacpan.org/pod/LWP#An-Example for an example
        my $req = HTTP::Request->new(GET => $fetch_url);
        my $resp = $ua->request($req);
        $total_requests++;
        # Handle HTTP status messages
        if ( $resp->is_success ) {
            $log->debug(qq(HTTP API request is successful for $file_id));
            #$log->info($resp->content);
            #$log->info(qq(file ID: $file_id; ) . status_message($resp->code));
            my $file = App::idgasmTools::File->new();
            my $parse_type;
            my $data = $parser->parse(data => $resp->content);
            # Check for parsing errors
            if ( ref($data) eq q(App::idgasmTools::Error) ) {
                $log->error(q(Error parsing downloaded ')
                    . uc($parse_type) . q(' data!));
                $log->error(q(Error message: ) . $data->error_msg);
                next HTTP_REQUEST;
            }
            my $populate_status = $file->populate(
                parse_module => $parser->parsing_module,
                data => $data,
            );
            # Check for idGames API request error
            if ( ref($populate_status) eq q(App::idgasmTools::Error) ) {
                $log->error(qq(ID: $file_id; Could not populate File object;));
                $log->error($populate_status->error_msg);
                $request_errors++;
            } else {
                my $full_path = $file->dir . $file->filename;
                $log->info(status_message($resp->code)
                    . sprintf(q( ID: %5u; ), $file_id)
                    . qq(path: $full_path));
                $file_map{$file_id} = $full_path;
            }
        } else {
            # HTTP error
            $log->logdie($resp->status_line);
        }
        $log->debug(qq(Finished parsing of ID $file_id));
        $file_id++;
        if ( $log->is_debug ) {
            if ( ! $cfg->defined(q(debug-noexit))
                && $total_requests > $debug_requests ) {
                last HTTP_REQUEST;
            }
        }
        # if die-on-error is defined, or die-on-error is set to 1
        # --no-die-on-error will set die-on-error to 0
        # if --no-die-on-error is not used, die-on-error will be 'undef'
        if (! $cfg->defined(q(die-on-error))
            || $cfg->get(q(die-on-error)) == 1){
            if ( $request_errors > 5 ) {
                $log->error(qq(Too many HTTP request errors!));
                $log->logdie(q|(Use --no-die-on-error to suppress)|);
            }
        }
        $log->debug(qq(Sleeping for $random_wait seconds...));
        sleep $random_wait;
    }

    my $OUTPUT;
    if ( $cfg->defined(q(output)) ) {
        $OUTPUT = open(q(>) . $cfg->get(q(output)));
    } else {
        $OUTPUT = *STDOUT;
    }
    #foreach my $key ( sort(keys(%file_map)) ) {
    foreach my $key ( sort {$a <=> $b} keys(%file_map) ) {
        say $OUTPUT $key . q(:) . $file_map{$key};
    }

    if ( $cfg->defined(q(output)) ) {
        close($OUTPUT);
    }

=cut

=back

=head1 AUTHOR

Brian Manning, C<< <brian at xaoc dot org> >>

=head1 BUGS

Please report any bugs or feature requests to the GitHub issue tracker for
this project:

C<< <https://github.com/spicyjack/public/issues> >>.

=head1 SUPPORT

You can find documentation for this script with the perldoc command.

    perldoc idgames_file_map.pl

=head1 COPYRIGHT & LICENSE

Copyright (c) 2013 Brian Manning, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

# конец!
# vim: set shiftwidth=4 tabstop=4