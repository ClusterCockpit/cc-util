#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use LWP::Simple;
use Number::Range;
use DBI;
use Log::Log4perl;
use REST::Client;
use JSON;

###### Configuration ######
# config path php-fpm container
my $cwd = '/root/monitor';
# load config
my %config = do "$cwd/config/config_meta.pl";
# setup Logger
Log::Log4perl->init("$cwd/config/log_meta.conf");
my $log = Log::Log4perl->get_logger("sinfo");
# setup REST
my $restClient = REST::Client->new();
$restClient->setHost('nginx:80');
$restClient->addHeader('X-AUTH-TOKEN', "$config{CC_token}");
$restClient->addHeader('accept', 'application/ld+json');
$restClient->addHeader('Content-Type', 'application/ld+json');
$restClient->getUseragent()->ssl_opts(SSL_verify_mode => 0); # Optional: Enable Cert Check Here 1/2
$restClient->getUseragent()->ssl_opts(verify_hostname => 0); # Optional: Enable Cert Check Here 1/2
# setup JSON
my $json = JSON->new->allow_nonref;
# setup subroutine for trimming records
sub  trim { my $s = shift; $s =~ s/^\s+|\s+$//g; return $s };

######## Variables ########
my $currentTime = time;
my $jobAddCount=0;
my $jobExistCount=0;
my $jobFinishedCount=0;
my $jobErrorCount=0;

##### Cluster Argument ######
my $cluster_id = '<CLUSTER>';
my $host       = '<HOSTNAME>';

#### Get Database Jobs ####
my $dsn ="DBI:mysql:database=".$config{DB_name}.";host=".$config{DB_host}.";port=".$config{DB_port};
my $dbh = DBI->connect(
    $dsn,
    $config{DB_user},
    $config{DB_passwd})
    or die "Could not connect to database: $DBI::errstr";
# prepare SQL database select
my $sth_select_running_jobs = $dbh->prepare(qq{
    SELECT id, user, job_id, array_job_id
    FROM job
    WHERE cluster = '$cluster_id'
        AND job_state = 'running'
    });
# execute query
$sth_select_running_jobs->execute;
my $job_lookup_raw = $sth_select_running_jobs->fetchall_hashref('id');
# disconnect database
$dbh->disconnect;

##### Build Index-Compatible Hashmap #####
my $job_lookup;

foreach my $job_raw (values %{$job_lookup_raw}) {

    my $jobLookupId = $job_raw->{job_id}.$job_raw->{array_job_id};

    if ( $config{DEBUG} ) {
        print "LOOKUP KEY FOR JOB $job_raw->{job_id} => $jobLookupId \n";
    }

    $job_lookup->{$jobLookupId} = $job_raw;
}

# get running jobs from Slurm
my $url = "http://<CLUSTER>.<DOMAIN>/<PATH>/squeue-l.txt";
my $raw_data = get($url);
die $log->error("SINFO \@$cluster_id: Can't GET $url") if (! defined $raw_data);

my @records = split(/\n/, $raw_data);
foreach my $line ( @records ) {
    next if $line =~ /JOBID/;

    my @data = split(/[ ]+/, trim($line));
    # get user_id
    my $user_id = trim($data[3]);
    # my $elapsed_time = trim($data[5]); # USEFUL?
    # process nodes
    my $hostlist = $data[9];
    my @node_list;

    if ( $hostlist =~ /m\[(.*)\]/ ) { # Process Input like: m[110,111,112-120] etc.
        my $rangelist = $1;
        $rangelist =~ s/-/../g;
        my $list = Number::Range->new($rangelist);
        my @nodes = $list->range;

        foreach my $node ( map { sprintf('m%04u', $_) } @nodes ) { # Force 4 Digits with leading zero if 3 digit nodenumber
            push @node_list, {hostname => "$node"};
        }

    } elsif ($hostlist =~ /^m[0-9]{4}/) { # Process single node entries [Viable / Wanted ?]
        if ( $config{DEBUG} ) { print "SINFO SINGLE NODE: $hostlist \n"; }
        push @node_list, {hostname => "$hostlist"};

    } else { # (Priority), (Resources), (Dependency) instead of Node-Range: Log if debug and Next Line
        if ( $config{DEBUG} ) { print "SINFO SKIP LINE: Found $hostlist \n";}
        next;
    }

    # process job_id
    my $job_id        = trim($data[0]);
    my $array_job_id  = 0;
    my $lookup_job_id = $job_id.$array_job_id;

    if ($job_id =~ m/^([0-9]+)_([0-9]+)$/) { # check / match for array job: Get natural ID, index, and lookup
        $job_id        = $1;
        $array_job_id  = $2;
        $lookup_job_id = $1.$2;

        if ( $config{VERBOSE} ) {
            $log->info("SINFO \@$cluster_id: Array Job $job_id found!");
        }

        if ( $config{DEBUG} ) {
            print "ARRAY JOB $job_id : SPLIT TO ID $1 AND INDEX $2 \n";
            print "ARRAY JOB $job_id : 'job_id' is '$job_id', 'array_job_id' is '$array_job_id'\n";
            print "ARRAY JOB $job_id : LOOKUP ID IS '$lookup_job_id'\n";
        }
    } else {
        if ( $config{DEBUG} ) {
            print "JOB $job_id LOOKUP ID IS: '$lookup_job_id'\n";
        }
    }

    # build payload for API
    my %jobMap = (
                  'jobId'      => "$job_id",
                  'arrayJobId' => "$array_job_id",
                  'partition'  => "",
                  'user'       => "$user_id",
                  'cluster'    => "$cluster_id",
                  'startTime'  => "$currentTime",
                  'resources'  => [@node_list],
    );

    # job is already in job table and running: do nothing, report ping if verbose
    if ( exists($job_lookup->{$lookup_job_id}) ) {

        if ( $config{VERBOSE} ) {
            $log->info("SINFO \@$cluster_id: Ping from running Job $jobMap{jobId} \[$jobMap{arrayJobId}\] (DB id: ".$job_lookup->{$lookup_job_id}->{id}.") from User $jobMap{user}");
        }
        $jobExistCount++;
        delete($job_lookup->{$lookup_job_id});

    # add job to job table, isRunning=true set by API
    } else {
        if ( $config{DEBUG} ) {
            print "USE /api/jobs/start_job WITH ".$json->encode( \%jobMap )."\n";

        } else {
            $restClient->POST('/api/jobs/start_job/', $json->encode( \%jobMap ));

            if ( $restClient->responseCode() eq '201' ) {
                if ( $config{VERBOSE} ) {
                    $log->info("SINFO \@$cluster_id: Add Job $jobMap{jobId} \[$jobMap{arrayJobId}\] from User $jobMap{user} : Started at $jobMap{startTime}");
                }
                $jobAddCount++;

            } else {
                my $errorResponse = $restClient->responseContent();
                if ( $config{VERBOSE} ) {
                    $log->error("SINFO \@$cluster_id: FAILED Add Job $jobMap{jobId} \[$jobMap{arrayJobId}\] from User $jobMap{user} : Started at $jobMap{startTime}");
                }
                $log->error("SINFO \@$cluster_id: FAILED API RESPONSE $errorResponse");
                $jobErrorCount++;
            }
        }
    }
}

## process finished jobs ##
foreach my $job ( values %$job_lookup ){
    # set stoptime, is_running=false set by API
    my %stopMap =  ( 'stopTime' => "$currentTime" );

    ## USE DB ID in new version
    if ( $config{DEBUG} ) {
        print "USE /api/jobs/stop_job/$job->{id} FOR JOB $job->{job_id} \[$job->{array_job_id}\] WITH ".$json->encode( \%stopMap )."\n";

    } else {
        $restClient->PUT("/api/jobs/stop_job/".$job->{id}, $json->encode( \%stopMap ));

        if ( $restClient->responseCode() eq '200' ) {
            if ( $config{VERBOSE} ) {
                $log->info("SINFO \@$cluster_id: Stop Job $job->{job_id} \[$job->{array_job_id}\] (DB id: $job->{id}) from User $job->{user} : Stopped at $stopMap{stopTime}");
            }
            $jobFinishedCount++;

        } else {
            my $errorResponse = $restClient->responseContent();
            if ( $config{VERBOSE} ) {
                $log->error("SINFO \@$cluster_id: FAILED Stop Job $job->{job_id} \[$job->{array_job_id}\] (DB id: $job->{id}) from User $job->{user} : Stopped at $stopMap{stopTime}");
            }
            $log->error("SINFO \@$cluster_id: FAILED API RESPONSE $errorResponse");
            $jobErrorCount++;
        }
    }
}

#### finish script ####
if ( $config{DEBUG} ) {
    print "DEBUG RUN FINISHED\n";
} else {
    $log->info("SINFO Ran on $currentTime for $cluster_id Add $jobAddCount, pinged $jobExistCount, close $jobFinishedCount, error $jobErrorCount");
}
