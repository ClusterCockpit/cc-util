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
use REST::Client;
use Net::NATS::Client

###############################################################################
#  Initialization
###############################################################################
my $timestamp;
my ($t0, $t1);
my $cwd = '<PATH TO CC-DOCKER>/data/monitor';
my $time = localtime();

##### Configuration #######
my %config = do "$cwd/config/config_metric.pl";
##########################
#
Log::Log4perl->init("$cwd/config/log_metric.conf");
my $log = Log::Log4perl->get_logger("gmondParser");

my $cluster = $ARGV[0];
if (not defined $cluster) {
    die $log->error("GMOND Usage: gmondParser.pl <CLUSTER>");
}

my $restClient;
my $natsClient;

if ( $config{USENATS} ) {
    $natsClient = Net::NATS::Client->new(uri => $config{NATS_url});
    $natsClient->connect() or die $log->error("Couldn't connect to $config{NATS_url}: $@");

 } else {
    $restClient = REST::Client->new();
    $restClient->setHost('https://localhost:8086'); #API URL when script runs on same host as InfluxDBv2
    $restClient->addHeader('Authorization', "Token $config{INFLUX_token}");
    $restClient->addHeader('Content-Type', 'text/plain; charset=utf-8');
    $restClient->addHeader('Accept', 'application/json');
    $restClient->getUseragent()->ssl_opts(SSL_verify_mode => 0); # Temporary: Disable Cert Check
    $restClient->getUseragent()->ssl_opts(verify_hostname => 0); # Temporary: Disable Cert Check
}

###############################################################################
#  Read in metric definition file
###############################################################################
my @events;
my @mlist;

my $ArithEnv = new Math::Expression(RoundNegatives => 1);

my %Vars = (
        EmptyList       =>      [()],
);

$ArithEnv->SetOpt(
    VarHash => \%Vars,
);

open FILE,"<$cwd/$cluster-events.txt" or die $log->error("GMOND Cannot open event file: $!");

my ($remote_type, $remote_host, $remote_port) = split ' ', <FILE>;

while ( <FILE> ) {
    my $line = $_;
    chomp $line;
    my @cols = split /:/,$line;

    my $name = $cols[0];
    my $measurement = $cols[1];
    my $metric = $cols[2];
    my $tmp = $metric;

    $tmp =~ s/[\+\-\*\/\(\)0-9]//g;
    my @ents = split ' ',$tmp;

    foreach my $ent ( @ents ) {
        push @mlist, $ent;
        $ArithEnv->VarSetScalar($ent, 0);
    }

    push @events, {
        'name' => $name,
        'measurement' => $measurement,
        'formula' => $metric,
        'metric' => $ArithEnv->Parse($metric),
    };
}
close FILE;

#setup measurement list
my %measurements;

foreach my $event ( @events ){
	my $key = $event->{'measurement'};
	if ( not exists $measurements{$key} ) {
		$measurements{$key} = 1;
	}
}

my $data;

if ($config{LOCALXML}) {
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
    or die $log->error("GMOND Couldn't connect to $remote_host:$remote_port: $@");

    $socket->autoflush(1);
    $t0 = [gettimeofday];

    while (<$socket>) {
        $data .= $_;
    }

    $t1 = [gettimeofday];
    sleep(1);
    $socket->close();

    if ($config{VERBOSE}) {
        $log->info("GMOND Socket Receive Time: ".tv_interval ($t0, $t1)."s");
    }
}

###############################################################################
#  Parse XML and input extracted metrics in database
###############################################################################
my $twig;
my $timestamp;

if ( $config{USENATS} ) {
    $twig = new XML::Twig(
        twig_handlers => {
            HOST    => \&hostHandlerNats,
            CLUSTER => \&setTimestamp }
    );

} else {
    $twig = new XML::Twig(
        twig_handlers => {
            HOST    => \&hostHandlerRest,
            CLUSTER => \&setTimestamp }
    );
}

$t0 = [gettimeofday];
$twig->parse( $data ) or die "Parse error";
$t1 = [gettimeofday];

if ($config{VERBOSE}) {
    $log->info("GMOND TIMESTAMP $cluster $timestamp");
    $log->info("GMOND PARSED IN $cluster ".tv_interval ($t0, $t1)."s");
}

###############################################################################
#  Twig callbacks
###############################################################################
sub setTimestamp
{
    my( $twig, $cluster)= @_;
    $timestamp = $cluster->{'att'}->{'LOCALTIME'};
}

sub hostHandlerRest
{
    my( $twig, $host)= @_;

    my $name = $host->{'att'}->{'NAME'};
    $name =~ s/\.<HPC>\.<DOMAIN>//; # USE YOUR DOMAIN REGEX HERE

    if ( $name =~ /[elw][0-9]{4}/ ){ # USE YOUR NODE-NAME REGEX HERE
        my @metrics= $host->children;
        my $time = $host->{'att'}->{'REPORTED'};

        foreach my $m ( @mlist ) {
            $ArithEnv->VarSetScalar($m, 0);
        }

        foreach my $metric ( @metrics ) {
            my $metricName  =  $metric->{'att'}->{'NAME'};
            my $metricValue =  $metric->{'att'}->{'VAL'};

            $metricName =~ s/\./_/g;

            if ( exists  $ArithEnv->{VarHash}->{$metricName}) {
                $ArithEnv->VarSetScalar($metricName, $metricValue) ;
            }
        }

        my %fieldString;

        foreach my $meas ( keys %measurements ){
            $fieldString{$meas} = '';
        }

        my $valueString = '';

        foreach my $event ( @events ) {
            my $result = $ArithEnv->EvalToScalar($event->{metric});
            $valueString .= ", ".$result;
            $fieldString{$event->{measurement}} .= "$event->{name}=$result,";
        }

        foreach my $meas ( keys %measurements ){
            $fieldString{$meas} = substr($fieldString{$meas}, 0, -1);
        }

        ## PERSIST: REST for influxv2-api
        foreach my $meas ( keys %measurements ){
            my $fields = $fieldString{$meas};
            my $measurement = "$meas,host=$name $fields $time";

            if ( $config{DEBUG} ) {
                print "USE /api/v2/write?org=$config{INFLUX_org}&bucket=$config{INFLUX_bucket}&precision=s WITH ".$measurement."\n";

            } else {
                # Use v2 API for Influx2
                $restClient->POST("/api/v2/write?org=$config{INFLUX_org}&bucket=$config{INFLUX_bucket}&precision=s", "$measurement");
                my $responseCode = $restClient->responseCode();

                if ( $responseCode eq '204') {
                    if ( $config{VERBOSE}) {
                        $log->info("GMOND API WRITE: CLUSTER $cluster MEASUREMENT $measurement");
                    }
                } else {
                    if ( $responseCode ne '422' ) { # Exclude High Frequency Error 422 - Temporary!
                        my $response = $restClient->responseContent();
                        $log->error("GMOND API WRITE ERROR CODE ".$responseCode.": ".$response);
                    };
                };
            };
        };
    };
};

sub hostHandlerNats
{
    my( $twig, $host)= @_;

    my $name = $host->{'att'}->{'NAME'};
    $name =~ s/\.<HPC>\.<DOMAIN>//; # USE YOUR DOMAIN REGEX HERE

    if ( $name =~ /[elw][0-9]{4}/ ){ # USE YOUR NODE-NAME REGEX HERE
        my @metrics = $host->children;
        my $time    = $host->{'att'}->{'REPORTED'};

        foreach my $m ( @mlist ) {
            $ArithEnv->VarSetScalar($m, 0);
        }

        foreach my $metric ( @metrics ) {
            my $metricName  =  $metric->{'att'}->{'NAME'};
            my $metricValue =  $metric->{'att'}->{'VAL'};

            $metricName =~ s/\./_/g;

            if ( exists  $ArithEnv->{VarHash}->{$metricName}) {
                $ArithEnv->VarSetScalar($metricName, $metricValue) ;
            }
        }

        ## PERSIST: NATS for cc-metric-store
        foreach my $event ( @events ) {
            my $result      = $ArithEnv->EvalToScalar($event->{metric});
            my $measurement = $event->{name}.",cluster=$cluster,hostname=$name,type=\"node\",type-id=0 value=$result $time";

            if ( $config{DEBUG} ) {
                print "USE 'updates' on ".$config{NATS_url}." WITH ".$measurement."\n";
            } else {
                # Simple Publisher without Response-Check (TODO)
                $natsClient->publish('updates', $measurement);
            };
        };
    };
};

#------------------------------------#

if ( $config{USENATS} ) {
    $natsClient->close();
}

if ( $config{DEBUG} ) {
    print "\nEND GANGLIA METRIC SCRIPT DEBUG RUN\n";
}
