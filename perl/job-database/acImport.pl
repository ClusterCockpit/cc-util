#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Data::Dumper;
use DBI;

my $database = $ARGV[0];
my $basedir = $ARGV[1];

my %attr = (
    PrintError => 1,
    RaiseError => 1
);

my $dbh = DBI->connect(
    "DBI:SQLite:dbname=$database", "", "", \%attr);

my $sth_insert_job = $dbh->prepare(qq{
    INSERT INTO job
    (job_id, user_id, cluster_id,
    start_time, stop_time, duration,
    num_nodes, has_profile)
    VALUES (?,?,?,?,?,?,?,?)
    });

my $sth_select_job = $dbh->prepare(qq{
    SELECT id, user_id, job_id, cluster_id,
           start_time, stop_time, duration, num_nodes
    FROM job
    WHERE job_id=?
    });

opendir my $dh, $basedir or die "can't open directory: $!";
while ( readdir $dh ) {
    chomp;
    next if $_ eq '.' or $_ eq '..';
    open(my $fh, "<","$basedir/$_");

    while ( my $line = <$fh> ) {
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
                print "Job $job_id already exists!\n";
            } else {
                $sth_insert_job->execute(
                    $job_id,
                    $user_id,
                    "emmy",
                    $start_time,
                    $stop_time,
                    $duration,
                    $num_nodes, 0);
            }
        }
    }

    close $fh or die "can't close file $!";
}
closedir $dh or die "can't close directory: $!";

$dbh->disconnect;

