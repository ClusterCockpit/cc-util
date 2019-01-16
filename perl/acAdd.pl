#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use LWP::Simple;
use Data::Dumper;
use DBI;
use Log::Log4perl;

# For robust path handling in CRON jobs
my $cwd = '/home.local/unrz254/MONITOR';

##### Configuration #######
my %config = do "$cwd/config.pl";
##########################

Log::Log4perl->init("$cwd/log.conf");
my $log = Log::Log4perl->get_logger("acAdd");

# Set to 1 for dry run without altering database
my $DRY = 0;
my $cluster_name = $ARGV[0];
my $date = $ARGV[1];

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

my $sth_insert_job = $dbh->prepare(qq{
    INSERT INTO job
    (user_id, job_id, num_nodes,
    start_time, stop_time, queue,
    duration, cluster_id)
    VALUES (?,?,?,?,?,?,?,$cluster_id)
    });

my $sth_job_add_node = $dbh->prepare(qq{
    INSERT INTO jobs_nodes (job_id, node_id)
    VALUES (?,?)
    });

my $sth_job_delete_node = $dbh->prepare(qq{
    DELETE FROM jobs_nodes
    WHERE job_id = ?
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

my $sth_select_job = $dbh->prepare(qq{
    SELECT id, user_id, job_id, num_nodes,
           start_time, stop_time, cluster_id,
           queue, duration
    FROM job
    WHERE job_id=?
    });

my $sth_select_nodes = $dbh->prepare(qq{
    SELECT node_id
    FROM jobs_nodes
    WHERE job_id=?
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

my $sth_update_job = $dbh->prepare(qq{
    UPDATE job
    SET user_id = ?,
        num_nodes = ?,
        start_time = ?,
        stop_time = ?,
        status = 'finished',
        queue = ?,
        duration = ?,
    WHERE id=?;
    });


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
} elsif ( $cluster_name eq 'woody' ) {
    $cluster_id = 4;
}

my $url = "http://$host.rrze.uni-erlangen.de/pbs4rzacct/";

# my $date = sprintf("%02d%02d",$month, $day);
my $raw_data = get($url.$date);
die $log->error("Can't GET $url $date") if (! defined $raw_data);

my $jobAddCount=0;
my $jobEditCount=0;
my @records = split(/\n/, $raw_data);

foreach my $line ( @records ) {

    if ( $line =~ /;E;(.*?);(.*)/ ) {
        my $jobinfo = $2;
        my @data = split(/ /, $jobinfo);
        my $job_id = $1;
        my $queue;
        my $user_id;
        my $start_time;
        my $stop_time;
        my @nodes;
        my $num_nodes;

        foreach my $prop ( @data ) {
            if ( $prop =~ /user=(.*)/ ) {
                $user_id = $1;
            }
            if ( $prop =~ /start=(.*)/ ) {
                $start_time = $1;
            }
            if ( $prop =~ /end=(.*)/ ) {
                $stop_time = $1;
            }
            if ( $prop =~ /queue=(.*)/ ) {
                $queue = $1;
            }
            if ( $prop =~ /exec_host=(.*)/ ) {
                my $hostlist = $1;
                my @hosts = split(/\+/, $hostlist);

                foreach my $host ( @hosts ) {
                    if ( $host =~ /(.*?)\/0/) {
                        push @nodes, $1;
                    }
                }

                $num_nodes = @nodes;
            }
        }

        my $duration = $stop_time - $start_time;

        # check if job already exists
        my @row = $dbh->selectrow_array($sth_select_job, undef, $job_id);

        if ( @row ) {
            if ( $row[0] ) {
                $log->info("Job $job_id already exists!");
                my $update_db = 0;

                my ($db_id,
                    $db_user_id,
                    $db_job_id,
                    $db_num_nodes,
                    $db_start_time,
                    $db_stop_time,
                    $db_cluster_id,
                    $db_queue,
                    $db_duration) = @row;

                @row = $dbh->selectrow_array(
                    $sth_select_user_id,
                    undef, $user_id);

                my ($uid) = @row;

                my $db_nodes = $dbh->selectall_hashref(
                    $sth_select_nodes,
                    'node_id',
                    undef,
                    ($db_id));

                # synchronize job info
                if ( $uid != $db_user_id ) {
                    $log->info("DIFF uid $uid => $db_user_id");
                    $update_db = 1;
                }
                if ( $num_nodes != $db_num_nodes ) {
                    $log->info("DIFF numnodes $num_nodes => $db_num_nodes");
                    $update_db = 1;
                }
                if ( $start_time != $db_start_time ) {
                    $log->info("DIFF start $start_time => $db_start_time");
                    $update_db = 1;
                }
                if ( $stop_time != $db_stop_time ) {
                    $log->info("DIFF stop $stop_time => $db_stop_time");
                    $update_db = 1;
                }
                if ( $queue ne $db_queue ) {
                    $log->info("DIFF queue $queue => $db_queue");
                    $update_db = 1;
                }
                if ( $duration != $db_duration ) {
                    $log->info("DIFF queue $duration => $db_duration");
                    $update_db = 1;
                }

                foreach my $node ( @nodes ) {
                    # check if node is missing in db
                    if ( not exists $db_nodes->{$node} ) {

                        @row = $dbh->selectrow_array(
                            $sth_select_node_id,
                            undef,
                            $node);

                        my ($nid) = @row;

                        $log->info("NODE miss $node: $db_id / $nid");
                        $sth_job_add_node->execute($db_id, $nid) unless $DRY;
                    }

                    $db_nodes->{$node}->{'inJob'} = 1;
                }

                # check if node is in db but not in job
                foreach my $node ( keys %$db_nodes ) {
                    if ( not exists $db_nodes->{$node}->{'inJob'} ) {
                        $log->info("NODE delete $node");
                        $sth_job_delete_node->execute($db_id) unless $DRY;
                    }
                }

                if ( $update_db ) {
                    $jobEditCount++;

                    $sth_update_job->execute(
                        $user_id,
                        $num_nodes,
                        $start_time,
                        $stop_time,
                        $queue,
                        $duration,
                        $db_id
                    ) unless $DRY;
                }
            } else {
                print "User id $user_id missing\n";
            }
        } else {
            @row = $dbh->selectrow_array($sth_select_user_id, undef, $user_id);
            my $uid = 0;
            my $jid = 0;

            # add user if missing
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
            } else {
                ($uid) = @row;
            }

            # insert new job
            $sth_insert_job->execute(
                $uid,
                $job_id,
                $num_nodes,
                $start_time,
                $stop_time,
                $queue,
                $duration) unless $DRY;

            # get id from added job
            @row = $dbh->selectrow_array(
                $sth_select_job_id,
                undef,
                $job_id) unless $DRY;

            if ( not @row ){
                die $log->error(" FAILED Add $job_id from $user_id ($uid) : $start_time to $stop_time on $num_nodes nodes ($duration s)");
            } else {
                ($jid) = @row;
            }

            $jobAddCount++;
            # $log->info("Add $job_id ($jid) from $user_id ($uid) : $start_time to $stop_time on $num_nodes nodes ($duration s)");

            # add nodes of job
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
                        $cluster_id) unless $DRY;

                    # get id for new added node
                    @row = $dbh->selectrow_array(
                        $sth_select_node_id,
                        undef,
                        $node);
                }

                my ($nid) = @row;
#                $log->debug("Add $node($jid, $nid)");
                $sth_job_add_node->execute($jid, $nid) unless $DRY;
            }
        }
    }
}

$log->info("acAdd ran on $date for $cluster_name: Add $jobAddCount, edit $jobEditCount");
$dbh->disconnect;
