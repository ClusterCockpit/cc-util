#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use v5.10;

use Time::HiRes qw(gettimeofday tv_interval);
use IO::Socket;
use XML::Twig;
use DBI;
use Log::Log4perl;
use File::Slurp;
use Math::Expression;

###############################################################################
#  Initialization
###############################################################################
my $timestamp;
my ($t0, $t1);
my $cwd = '/home.local/unrz254/MONITOR/';
my $time = localtime();

##### Configuration #######
my %config = do "$cwd/config.pl";
##########################
#
Log::Log4perl->init("$cwd/log.conf");
my $log = Log::Log4perl->get_logger("gmondParser");

my $cluster = $ARGV[0];
if (not defined $cluster) {
    die $log->error("Usage: gmondParser.pl <CLUSTER>");
}

###############################################################################
#  Read in metric definition file
###############################################################################
my @events;
my @mlist;
my $columnString = '';

my $ArithEnv = new Math::Expression(RoundNegatives => 1);

my %Vars = (
        EmptyList       =>      [()],
  );

$ArithEnv->SetOpt(
    VarHash => \%Vars,
);

open FILE,"<$cwd/$cluster-events.txt" or die $log->error("Cannot open event file: $!");

my ($remote_type, $remote_host, $remote_port) = split ' ', <FILE>;

while ( <FILE> ) {
    my $line = $_;
    chomp $line;
    my @cols = split /:/,$line;

    my $name = $cols[0];
    my $metric = $cols[1];
    my $tmp = $metric;

    $tmp =~ s/[\+\-\*\/\(\)0-9]//g;
    my @ents = split ' ',$tmp;

    foreach my $ent ( @ents ) {
        push @mlist, $ent;
        $ArithEnv->VarSetScalar($ent, 0);
    }

    $columnString .= ", ".$name;

    push @events, {
        'name' => $name,
        'formula' => $metric,
        'metric' => $ArithEnv->Parse($metric),
    };
}
close FILE;

my $data;

if ( $config{DEBUG}) {
    $data = read_file('out.xml');
} else {
###############################################################################
#  RCV XML from gmond
###############################################################################
my $socket = IO::Socket::INET->new(
    Timeout => 10,
    Proto   => "tcp",
    Type    => SOCK_STREAM,
    PeerAddr=> "$remote_host",
    PeerPort=> "$remote_port")
    or die $log->error("Couldn't connect to $remote_host:$remote_port: $@");

$socket->autoflush(1);
$t0 = [gettimeofday];

while (<$socket>) {
    $data .= $_;
}

$t1 = [gettimeofday];
sleep(1);
$socket->close();
$log->debug("Socket Receive Time: ".tv_interval ($t0, $t1)."s");
}

###############################################################################
#  Parse XML and input extracted metrics in database
###############################################################################
my $twig= new XML::Twig(
    twig_handlers => {
        HOST    => \&hostHandler,
        CLUSTER => \&setTimestamp }
);

my $dbh;

if ( not $config{DEBUG}){
$dbh = DBI->connect(
    'DBI:mysql:'.$config{DB_name},
    $config{DB_user},
    $config{DB_passwd})
    or die "Could not connect to database: $DBI::errstr";
}

my $sth = $dbh->prepare("SELECT id, node_id FROM node");
$sth->execute();
my $node_lookup = $sth->fetchall_hashref('node_id');

$t0 = [gettimeofday];
$twig->parse( $data ) or die "Parse error";
$t1 = [gettimeofday];
$log->debug("Parse Time: ".tv_interval ($t0, $t1)."s");
$log->info("TIMESTAMP $cluster $timestamp");

$dbh->disconnect() unless $config{DEBUG};

###############################################################################
#  Twig callbacks
###############################################################################
sub setTimestamp
{
    my( $twig, $cluster)= @_;
    $timestamp = $cluster->{'att'}->{'LOCALTIME'};
}

sub hostHandler
{
    my( $twig, $host)= @_;

    my $name = $host->{'att'}->{'NAME'};

    if ( $name =~ /[el][0-9]{4}/ ){
        my @metrics= $host->children;
        my $ip = $host->{'att'}->{'IP'};
        my $time = $host->{'att'}->{'REPORTED'};

        foreach my $m ( @mlist ) {
            $ArithEnv->VarSetScalar($m, 0);
        }

        foreach my $metric ( @metrics ) {
            my $metricName =  $metric->{'att'}->{'NAME'};
            my $metricValue =  $metric->{'att'}->{'VAL'};

            $metricName =~ s/\./_/g;

            if ( exists  $ArithEnv->{VarHash}->{$metricName}) {
                $ArithEnv->VarSetScalar($metricName, $metricValue) ;
            }
        }

        my $valueString = '';

        foreach my $event ( @events ) {
            my $result = $ArithEnv->EvalToScalar($event->{metric});
            $valueString .= ", ".$result;
        }

        my $node_id = $node_lookup->{$name}->{id};
        my $DB_stmt = "INSERT INTO data (node_id, epoch $columnString) VALUES ($node_id, $time $valueString)";
	#        $log->info("$DB_stmt");
	$dbh->do($DB_stmt);
    }
}
