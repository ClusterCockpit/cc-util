#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use LWP::Simple;
use Data::Dumper;
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
my $log = Log::Log4perl->get_logger("qstat");
# setup REST
my $restClient = REST::Client->new();
$restClient->setHost('nginx:80');
$restClient->addHeader('X-AUTH-TOKEN', "$config{CC_token}");
$restClient->addHeader('accept', 'application/ld+json');
$restClient->addHeader('Content-Type', 'application/ld+json');
$restClient->getUseragent()->ssl_opts(SSL_verify_mode => 0); # Temporary: Disable Cert Check 1/2
$restClient->getUseragent()->ssl_opts(verify_hostname => 0); # Temporary: Disable Cert Check 2/2
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

##### Parse Argument ######
my $cluster_id = $ARGV[0];
my $host;
if      ( $cluster_id eq '<CLUSTER1>' ) { $host = '<HOSTNAME1>' }
elsif   ( $cluster_id eq '<CLUSTER2>' ) { $host = '<HOSTNAME2>' }
else    { die $log->error("QSTAT Unknown Cluster_ID : $cluster_id")};

#### Get Database Jobs ####
my $dsn ="DBI:mysql:database=".$config{DB_name}.";host=".$config{DB_host}.";port=".$config{DB_port};
my $dbh = DBI->connect(
    $dsn,
    $config{DB_user},
    $config{DB_passwd})
    or die "Could not connect to database: $DBI::errstr";
# prepare SQL database select: !! meta_data not viable as soon as whole jobscripts are saved there!!
my $sth_select_running_jobs = $dbh->prepare(qq{
    SELECT id, user_id, job_id, meta_data
    FROM job
    WHERE cluster_id = '$cluster_id'
        AND is_running = true
    });
# execute query
$sth_select_running_jobs->execute;
my $job_lookup_raw = $sth_select_running_jobs->fetchall_hashref('id');
# disconnect database
$dbh->disconnect;

##### Build Index-Compatible Hashmap #####
my $job_lookup;

foreach my $job_raw (values %{$job_lookup_raw}) {

    my $jobId     = $job_raw->{job_id};
    my $meta      = $json->decode($job_raw->{meta_data});
    my $jobIdLong = $meta->{jobIdLong};

    if ($jobIdLong) {
        $jobIdLong =~ s/\.($host).*//;

        if ($jobIdLong =~ m/^([0-9]*)\[([0-9])\]$/) { # match and get natural ID and index
            $jobId = $1.$2;

            if ( $config{DEBUG} ) {
                print "INDEXED DATABASE JOB SPLIT TO ID $1 AND INDEX $2 : LOOKUP KEY => $jobId \n";
            }
        }
    }

    delete($job_raw->{meta_data}); # reduce size
    $job_lookup->{$jobId} = $job_raw;
}

##### Get PBS Records #####
my $url = "http://$host.<DOMAIN>/<PATH>/qstatrn";
my $raw_data = get($url);
die $log->error("QSTAT \@$cluster_id: Can't GET $url") if (! defined $raw_data);
my @records = split(/\n/, $raw_data);

#### Update CC via API ####
foreach my $line ( @records ) {
    if ( $line =~ /^[0-9]+/ ) {
        # get data
        my @data = split(/[ ]+/, $line);
        # get user_id
        my $user_id = trim($data[1]);

        # process nodes
        my $hostlist = $data[11];
        my @hosts = split(/\+/, $hostlist);
        my @nodes;
        foreach my $host ( @hosts ) {
            if ( $host =~ /(.*?)\/0/) {
                push @nodes, $1;
            }
        }
        my $node_list = join '|', @nodes;

        # process job_id
        my $job_id_long = trim($data[0]);
        my $job_id      = $job_id_long =~ s/\.($host).*//r;
        my $lookup_id;

        if ($job_id =~ m/^([0-9]*)\[([0-9])\]$/) { # match and get natural ID and index
            $job_id     = $1;
            $lookup_id  = $1.$2;

            if ( $config{VERBOSE} ) {
                $log->info("QSTAT \@$cluster_id: Array Job $job_id_long found!");
            }

            if ( $config{DEBUG} ) {
                print "ARRAY JOB $job_id_long SPLIT TO ID $1 AND INDEX $2 \n";
                print "ARRAY JOB $job_id_long REASSIGNED JOBID FOR LOOKUP IS: ".$lookup_id."\n";
            }
        } else {
            $lookup_id = $job_id;

            if ( $config{DEBUG} ) {
                print "JOB $job_id_long LOOKUP IS: ".$lookup_id."\n";
            }
        }

        # build payload for API
        my %jobMap = (
                      'jobId'     => $job_id + 0, # hacky way of converting str to int
                      'userId'    => "$user_id",
                      'clusterId' => "$cluster_id",
                      'startTime' => $currentTime,
                      'nodeList'  => "$node_list",
                      'metaData'  => {'jobIdLong' => $job_id_long},
        );

        # job is already in job table and running: do nothing, report ping if verbose
        if ( exists($job_lookup->{$lookup_id}) ) {

            if ( $config{VERBOSE} ) {
                $log->info("QSTAT \@$cluster_id: Ping from running Job ".$jobMap{jobId}." (DB id: ".$job_lookup->{"$jobMap{jobId}"}->{id}.") from User ".$jobMap{userId});
            }
            $jobExistCount++;
            delete($job_lookup->{$lookup_id});

        # add job to job table, isRunning=true set by API
        } else {
            if ( $config{DEBUG} ) {
                print "USE /api/jobs/start_job WITH ".$json->encode( \%jobMap )."\n";

            } else {
                $restClient->POST('/api/jobs/start_job/', $json->encode( \%jobMap ));

                if ( $restClient->responseCode() eq '201' ) {
                    if ( $config{VERBOSE} ) {
                        $log->info("QSTAT \@$cluster_id: Add Job ".$jobMap{jobId}." from User ".$jobMap{userId}." : Started at ".$jobMap{startTime});
                    }
                    $jobAddCount++;

                } else {
                    my $errorResponse = $restClient->responseContent();
                    if ( $config{VERBOSE} ) {
                        $log->error("QSTAT \@$cluster_id: FAILED Add Job ".$jobMap{jobId}." from User ".$jobMap{userId}." : Started at ".$jobMap{startTime});
                    }
                    $log->error("QSTAT \@$cluster_id: FAILED API RESPONSE $errorResponse");
                    $jobErrorCount++;
                }
            }
        }
    }
}

## process finished jobs ##
foreach my $job ( values %$job_lookup ){
    # set stoptime, is_running=false set by API
    my %stopMap =  ( 'stopTime' => $currentTime );

    ## USE DB ID in new version
    if ( $config{DEBUG} ) {
        print "USE /api/jobs/stop_job/".$job->{id}." FOR JOB ".$job->{job_id}." WITH ".$json->encode( \%stopMap )."\n";

    } else {
        $restClient->PUT("/api/jobs/stop_job/".$job->{id}, $json->encode( \%stopMap ));

        if ( $restClient->responseCode() eq '200' ) {
            if ( $config{VERBOSE} ) {
                $log->info("QSTAT \@$cluster_id: Stop Job ".$job->{job_id}." (DB id: ".$job->{id}.") from User ".$job->{user_id}." : Stopped at ".$stopMap{stopTime});
            }
            $jobFinishedCount++;

        } else {
            my $errorResponse = $restClient->responseContent();
            if ( $config{VERBOSE} ) {
                $log->error("QSTAT \@$cluster_id: FAILED Stop Job ".$job->{job_id}." (DB id: ".$job->{id}.") from User ".$job->{user_id}." : Stopped at ".$stopMap{stopTime});
            }
            $log->error("QSTAT \@$cluster_id: FAILED API RESPONSE $errorResponse");
            $jobErrorCount++;
        }
    }
}

#### finish script ####
if ( $config{DEBUG} ) {
    print "DEBUG RUN FINISHED\n";
} else {
    $log->info("QSTAT Ran on $currentTime for $cluster_id Add $jobAddCount, pinged $jobExistCount, close $jobFinishedCount, error $jobErrorCount");
}
