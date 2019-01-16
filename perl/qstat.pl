#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use LWP::Simple;
use Data::Dumper;
use File::Slurp;
use DBI;
use Log::Log4perl;

my $cwd = '/home.local/unrz254/MONITOR';

##### Configuration #######
my %config = do "$cwd/config.pl";
##########################

Log::Log4perl->init("$cwd/log.conf");
my $log = Log::Log4perl->get_logger("qstat");

# Set to 1 for dry run without altering database
my $DRY = 0;
my $cluster_name = $ARGV[0];

sub  trim { my $s = shift; $s =~ s/^\s+|\s+$//g; return $s };

my $dbh = DBI->connect(
    'DBI:mysql:'.$config{DB_name},
    $config{DB_user},
    $config{DB_passwd})
    or die "Could not connect to database: $DBI::errstr";

my $host='eadm';
my $cluster_id = 1;  #1=>Emmy, 2=>Lima, 3=>Meggie, 4=>WoodY
my $num_cores = 20;
my $num_processors = 40;
my $prefix = 'e';
my $sql_stmt;

if ( $cluster_name eq 'lima' ){
    $cluster_id = 2;
    $num_cores = 12;
    $num_processors = 24;
    $prefix = 'l';
    $host = 'ladm1';
} elsif ( $cluster_name eq 'meggie' ) {
    $cluster_id = 3;
    $num_cores = 20;
    $num_processors = 40;
    $prefix = 'm';
}

# prepare SQL database queries
my $sth_insert_job = $dbh->prepare(qq{
    INSERT INTO job
    (user_id, job_id, num_nodes,
    start_time, duration, queue, cluster_id, is_running)
    VALUES (?,?,?,?,?,?,$cluster_id,true)
    });

my $sth_job_add_node = $dbh->prepare(qq{
    INSERT INTO jobs_nodes (job_id, node_id)
    VALUES (?,?)
    });

my $sth_insert_node = $dbh->prepare(qq{
    INSERT INTO node (node_id, rack_id, status, num_cores, num_processors, cluster)
    VALUES (?,?,?,?,?,?)
    });

my $sth_insert_user = $dbh->prepare(qq{
    INSERT INTO user (user_id, uid, name, email, active)
    VALUES (?,99999,?,?,0)
    });

my $sth_user_add_group = $dbh->prepare(qq{
    INSERT INTO users_groups (user_id, group_id)
    VALUES (?,?)
    });

my $sth_select_running_jobs = $dbh->prepare(qq{
    SELECT id, user_id, job_id, start_time, cluster_id, num_nodes, queue
    FROM job
    WHERE cluster_id = $cluster_id
    AND is_running=true
    });

my $sth_select_user_id = $dbh->prepare(qq{
    SELECT id
    FROM user
    WHERE username=?
    });

my $sth_select_group_id = $dbh->prepare(qq{
    SELECT id
    FROM unix_group
    WHERE group_id=?
    });

my $sth_select_job_id = $dbh->prepare(qq{
    SELECT id
    FROM job
    WHERE job_id=?
    });

my $sth_select_node_id = $dbh->prepare(qq{
    SELECT id
    FROM node
    WHERE node_id=?
    });

my $sth_update_running_job = $dbh->prepare(qq{
    UPDATE job
    SET duration = ?
    WHERE id=?
    });


my $sth_close_running_job = $dbh->prepare(qq{
    UPDATE job
    SET is_running = false,
    stop_time = ?,
    duration = ?
    WHERE id=?
    });

# get all running jobs in jobs table
$sth_select_running_jobs->execute;
my $job_lookup  = $sth_select_running_jobs->fetchall_hashref('job_id');

# get all running jobs from PBS
my $url = "http://$host.rrze.uni-erlangen.de/cgi-bin/hpcacct-mon/qstatrn";
my $raw_data = get($url);
die $log->error("Can't GET $url") if (! defined $raw_data);

my $currentTime = time;
my $jobAddCount=0;
my $jobExistCount=0;
my $jobFinishedCount=0;
my @records = split(/\n/, $raw_data);

foreach my $line ( @records ) {

    if ( $line =~ /^[0-9]+/ ) {
        my @data = split(/[ ]+/, $line);
        my $job_id = trim($data[0]);
        my $user_id = trim($data[1]);
        my $queue = trim($data[2]);
        my $elapsed_time = trim($data[10]);
        my $num_nodes = trim($data[5]);
        my $hostlist = $data[11];
        my @nodes;

        my @timeElapsed = split(/:/, $elapsed_time);
        my $duration = 0;

        if ( $elapsed_time ne '--' ) {
            if ( $cluster_id == 2 ){
                $duration = $timeElapsed[0]*3600+$timeElapsed[1]*60;
            } else {
                $duration = $timeElapsed[0]*3600+$timeElapsed[1]*60+$timeElapsed[2];
            }
        }

        my @hosts = split(/\+/, $hostlist);

        foreach my $host ( @hosts ) {
            if ( $host =~ /(.*?)\/0/) {
                push @nodes, $1;
            }
        }

        my $start_time = $currentTime - $duration;

        if ( exists($job_lookup->{$job_id}) ) { # job is already in job table
		my $dur = $currentTime - $job_lookup->{$job_id}->{start_time};
		#       $log->info("Job $job_id already exists: $dur s !");
	    
            $sth_update_running_job->execute(
                $currentTime - $job_lookup->{$job_id}->{start_time},
                $job_lookup->{$job_id}->{id});

            $jobExistCount++;
            delete($job_lookup->{$job_id});
        } else { # add job to job table
            my @row = $dbh->selectrow_array($sth_select_user_id, undef, $user_id);
            my $uid = 0;
            my $jid = 0;

            # add user if not yet existing
            if ( not @row ) {
                $log->info("Add User $user_id");
                $sth_insert_user->execute(
                    $user_id, 'John Doe', $user_id.'@mailhub.uni-erlangen.de') unless $DRY;

                my @entry = $dbh->selectrow_array(
                    $sth_select_user_id,
                    undef,
                    $user_id) unless $DRY;

                ($uid) = @entry;

                # try to find group
                $user_id =~ /^(\w{4})/;
                my $group_id = $1;

                my @group = $dbh->selectrow_array(
                    $sth_select_group_id,
                    undef,
                    $group_id) unless $DRY;

                if ( not @group ){
                    $log->info("No matching group $group_id");
                } else {
                    # add user to group
                    my ($gid) = @group;
                    $log->info("Add $user_id to $group_id");
                    $sth_user_add_group->execute($uid, $gid) unless $DRY;
                }
            } else { # user exists already
                ($uid) = @row;
            }

            # insert new job
            $sth_insert_job->execute(
                $uid,
                $job_id,
                $num_nodes,
                $start_time,
                $duration,
                $queue);

            # get id from added job
            @row = $dbh->selectrow_array(
                $sth_select_job_id,
                undef,
                $job_id);

            if ( not @row ){
                die $log->error("FAILED Add $job_id from $user_id : $start_time on $num_nodes nodes ($duration s)");
            } else {
                ($jid) = @row;
            }

            $jobAddCount++;
	    #       $log->info("Add $job_id ($jid) from $user_id ($uid) : $start_time on $num_nodes nodes ($duration s)");

            # add nodes for job
            foreach my $node ( @nodes ) {
                # get node id
                @row = $dbh->selectrow_array(
                    $sth_select_node_id,
                    undef,
                    $node);

                # add node if missing
                if ( not @row ){
                    $node =~ /$prefix([0-9]{2})/;
                    my $rack_id = $1;
                    $log->info("Add missing node $node $rack_id") ;

                    $sth_insert_node->execute(
                        $node,
                        $rack_id,
                        'free',
                        $num_cores,
                        $num_processors,
                        $cluster_id);

                    # get id for new added node
                    @row = $dbh->selectrow_array(
                        $sth_select_node_id,
                        undef,
                        $node);
                }

                my ($nid) = @row;
                $log->debug("Add $node($jid, $nid)");
                $sth_job_add_node->execute($jid, $nid);
            }
        }
    }
}

# process finished jobs
foreach my $job ( values %$job_lookup ){
    $jobFinishedCount++;
    #   $log->info("Finish job ".$job->{'job_id'});

    # unset is_running flag and set stop_time
    $sth_close_running_job->execute(
        $currentTime,
        $currentTime - $job->{start_time},
        $job->{id});
}

$log->info("qstat ran on $currentTime for $cluster_name: Add $jobAddCount, update $jobExistCount, close $jobFinishedCount");
$dbh->disconnect;
