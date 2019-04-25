#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Data::Dumper;
use Getopt::Long;
use DateTime::Format::Strptime;
use DBI;

my $database = 'jobDB';
my @conditions;
my ($add, $from, $to);

my %attr = (
    PrintError => 1,
    RaiseError => 1
);

my $dbh = DBI->connect(
    "DBI:SQLite:dbname=$database", "", "", \%attr)
 or die("Cannot connect to database $database\n");

my $dateParser =
DateTime::Format::Strptime->new(
    pattern => '%d.%m.%Y',
    time_zone => 'Europe/Berlin',
    on_error  => 'undef'
);

sub parseDate {
    my $str = shift;
    my $dt;

    if ( $str ){
        $dt = $dateParser->parse_datetime($str);

        if ( $dt ) {
            return $dt->epoch;
        } else {
            print "Cannot parse datetime string $str: Ignoring!\n";
            return 0;
        }
    } else {
        return 0;
    }
}

sub parseDuration {
    my $str = shift;

    if ( $str =~ /([0-9]+)h/ ) {
        return $1 * 3600;

    } elsif ( $str =~ /([0-9]+)m/ ) {
        return $1 * 60;

    } elsif ( $str =~ /([0-9]+)s/ ) {
        return $1;

    } elsif ( $str =~ /([0-9]+)/ ) {
        return $1;

    } else {
        print "Cannot parse duration string $str: Ignoring!\n";
        return 0;
    }
}

sub processRange {
    my $lower = shift;
    my $upper = shift;

    if ( $lower && $upper ){
        return (3, $lower, $upper);
    } elsif ( $lower && !$upper ){
        return (1, $lower, 0);
    } elsif ( !$lower && $upper ){
        return (2, 0, $upper);
    }
}

sub buildCondition {
    my $name = shift;

    if ( $add ) {
        if ( $add == 1 ) {
            push @conditions, "$name < $from";
        } elsif ( $add == 2 ) {
            push @conditions, "$name > $to";
        } elsif ( $add == 3 ) {
            push @conditions, "$name BETWEEN $from AND $to";
        }
    }
}

my $mode = 0;
my $user_id = '';
my @numnodes;
my @starttime;
my @duration;

GetOptions (
    'mode' => \$mode,
    'user=s' => \$user_id,
    'numnodes=i{2}' => \@numnodes,
    'starttime=s{2}' => \@starttime,
    'duration=s{2}' => \@duration
) or die("Error in command line arguments\n");

my $query = 'SELECT * FROM job';

if ( @numnodes ) {
    ($add, $from, $to) = processRange($numnodes[0], $numnodes[1]);
    buildCondition('num_nodes');
}

if ( @starttime ) {
    ($add, $from, $to) = processRange( parseDate($starttime[0]), parseDate($starttime[1]));
    buildCondition('start_time');
}

if ( @duration ) {
    ($add, $from, $to) = processRange( parseDuration($duration[0]), parseDuration($duration[1]));
    buildCondition('duration');
}

if ( @conditions ){
    $query .= ' WHERE ';
    my $conditionstring = join(' AND ',@conditions);
    $query .= $conditionstring;
}

print "$query\n";

