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
my $log = Log::Log4perl->get_logger("template");

# Set to 1 for dry run without altering database
my $DRY = 0;

# Process script arguments
my $cluster_name = $ARGV[0];

# Local helper routines
sub  trim { my $s = shift; $s =~ s/^\s+|\s+$//g; return $s };

# Initialization
my $dbh = DBI->connect(
    'DBI:mysql:'.$config{DB_name},
    $config{DB_user},
    $config{DB_passwd})
    or die "Could not connect to database: $DBI::errstr";


# prepared SQL statements
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

# initialize lookup hashes
$sth_select_running_jobs->execute;
my $job_lookup  = $sth_select_running_jobs->fetchall_hashref('job_id');

# Data import processing


$log->info("qstat ran on $currentTime for $cluster_name: Add $jobAddCount, update $jobExistCount, close $jobFinishedCount");
$dbh->disconnect;
