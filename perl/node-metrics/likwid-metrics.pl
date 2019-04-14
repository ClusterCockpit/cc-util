#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Sys::Hostname;
use Data::Dumper;

##### CONFIGURATION  #############################
my $SAMPLETIME = 10;

my $LIKWID_COMMAND = 'likwid-perfctr';
my $LIKWID_OPTIONS = '-f -O -S 3s';

my @LIKWID_GROUPS = (
    'MEM_DP',
    'FLOPS_SP'
);

# Path for IB statistics
my $IBLID = '/sys/class/infiniband/mlx4_0/ports/1/lid';

# File for network traffic
my $NETSTATFILE = '/proc/net/dev';

# File for memory information
my $MEMSTATFILE = '/proc/meminfo';

# File for load information
my $LOADSTATFILE = '/proc/loadavg';

# Curl to write directly into InfluxDB
my $CURL = '/usr/bin/curl';
my $CURLHOST = 'testhost.testdomain.de:8090';
my $CURLDB = 'testcluster';

# measurements used: node, socket, memory, cpu

my %METRICS = (
    'mem_bw' => {
        'measurement' => 'socket',
        'match' => 'Memory bandwidth',
        'group' => 'MEM_DP',
        'stat'  => 1,
        'field' => 'mem_bw'
    },
    'flops_dp' => {
        'measurement' => 'cpu',
        'match' => 'MFLOP',
        'group' => 'MEM_DP',
        'stat'  => 1,
        'field' => 'flops_dp'
    },
    'flops_sp' => {
        'measurement' => 'cpu',
        'match' => 'SP MFLOP',
        'group' => 'FLOPS_SP',
        'stat'  => 1,
        'field' => 'flops_sp'
    },
    'cpi' => {
        'measurement' => 'cpu',
        'match' => 'CPI',
        'group' => 'MEM_DP',
        'stat'  => 4,
        'field' => 'cpi'
    },
    'clock' => {
        'measurement' => 'cpu',
        'match' => 'Clock',
        'group' => 'MEM_DP',
        'stat'  => 4,
        'field' => 'clock'
    },
    'rapl_power' => {
        'measurement' => 'socket',
        'match' => 'Power \[W\]',
        'group' => 'MEM_DP',
        'stat'  => 1,
        'field' => 'rapl_power'
    }
);
##### END CONFIGURATION OPTIONS ##################


##### SET ENVIRONMENT ############################
my $HOST = hostname();
my $CLUSTER = 'default';

if ( $HOST =~ /^broad/  ){
    $CLUSTER = 'TestCluster';
} elsif ( $HOST =~ /^e/ ){
    $CLUSTER = 'Emmy';
}

my %TOPOLOGY = do "./$CLUSTER.pl";
##### END SET ENIRONMENT #########################

sub sanitize {
    my $value = shift;

    if ( not defined $value or $value eq '-' ){
        return 0;
    } else {
        return $value;
    }
}

sub printResults {
    my $results = shift;

    foreach my $key ( keys %$results ){

        if ( $key eq 'node' or $key eq 'network'  ){
            print "$key,cluster=$CLUSTER,host=$HOST ";
            my $fields = '';

            while( my($metric, $value) = each %{$results->{$key}} ){
                $fields .= "$metric=$value,";
            }
            $fields = substr $fields, 0, -1;
            print "$fields\n";
        } else {
            for my $i ( 0 .. $#{$results->{$key}} ){
                print "$key,cluster=$CLUSTER,host=$HOST,id=$i ";
                my $fields = '';

                while( my($metric, $value) = each %{$results->{$key}->[$i]} ){
                    $fields .= "$metric=$value,";
                }
                $fields = substr $fields, 0, -1;
                print "$fields\n";
            }
        }
    }
}

sub getNetstats {
    my $res = shift;

    if ( -r $NETSTATFILE) {
        if (open(FILE, "<$NETSTATFILE")) {

            while ( my $ll = <FILE>) {
                my @ls = split(' ', $ll);
                if ($ls[0] =~ /(.*):/) {
                    $res->{$1."_traffic_read"} = $ls[1];
                    $res->{$1."_traffic_write"} = $ls[9];
                }
            }

            close(FILE);
        }
    }
}

sub getIbstats {
    my $res = shift;

    if (-r "$IBLID") {
        if (open(FILE, "/usr/sbin/perfquery -r `cat $IBLID` 1 0xf000 |")) {
            my $traffic_total = 0;

            while ( my $ll = <FILE>) {
                my @ls = ( $ll =~ m/(.+:)\.+([0-9]*)/ );
                # from the perfquery manpage:
                # Note: In PortCounters, PortCountersExtended, PortXmitDataSL, and PortRcvDataSL, components that represent Data (e.g. PortXmitData
                # and PortRcvData)  indicate octets divided by 4 rather than just octets.
                if ( defined($ls[0]) && $ls[0] =~ m/PortRcvData:|RcvData:/) {
                    $res->{ib_traffic_read} = $ls[1] * 4;
                    $traffic_total += $ls[1] * 4;
                } elsif ( defined($ls[0]) && $ls[0] =~ m/PortXmitData:|XmtData:/) {
                    $res->{ib_traffic_write} = $ls[1] * 4;
                    $traffic_total += $ls[1] * 4;
                }
            }

            $res->{ib_traffic_total} = $traffic_total ;
            close(FILE);
        }
    }
}

sub getLikwid {
    my $res = shift;
    my $LIKWIDEX = undef;
    # my $matchpattern =  join('|', map "^$_", keys %METRICS);

    foreach my $group ( @LIKWID_GROUPS ){

        my $matchpattern;
        my %metrics;

        foreach my $key ( keys %METRICS ){
            if ( $group eq $METRICS{$key}->{group} ){
                my $pattern = $METRICS{$key}->{match};
                $matchpattern .= "^$pattern|";
                $pattern =~ s/\\//g;
                $metrics{$pattern} = $METRICS{$key};
            }
        }
        $matchpattern = substr $matchpattern, 0, -1;
        # print "$matchpattern\n";


        if ( open($LIKWIDEX, "$LIKWID_COMMAND -g $group $LIKWID_OPTIONS |") ){
            while ( my $line = <$LIKWIDEX> ){
                if ( $line =~ /($matchpattern)/ ){
                    # print "$line \n";
                    my $metric = $metrics{$1};
                    my $measurement = $metric->{'measurement'};
                    my $fieldname = $metric->{'field'};
                    my @entries = split ',', $line;

                    if ( $line =~ /STAT/ ){
                        $res->{'node'}->{$fieldname} = $entries[$metric->{'stat'}];
                    } else {
                        my @values;
                        shift(@entries);

                        # print "$measurement -> $fieldname\n";

                        if ( $measurement eq 'cpu' ){
                            foreach my $i ( 0 .. $#entries-1 ){
                                $values[$i] = sanitize($entries[$i]);
                            }
                        } else {
                            foreach my $i ( 0 .. $#entries-1 ){
                                if ( $entries[$i] ne '0' ){
                                    # print "$measurement -> $entries[$i]\n";
                                    push @values, $entries[$i];
                                }
                            }
                        }

                        for my $i ( 0 .. $#values ){
                            $res->{$measurement}->[$i]->{$fieldname} = $values[$i];
                        }
                    }
                }
            }
        }
    }
}

sub getMemstat {
    my $res = shift;

    if ( -r $MEMSTATFILE) {
        if (open(FILE, '<'.$MEMSTATFILE)) {
            my %memstats;

            while ( my $ll = <FILE>) {
                my @ls = split(' ', $ll);
                $memstats{$ls[0]} = $ls[1];
            }

            close(FILE);
            $res->{mem_used} = $memstats{'MemTotal:'} - ($memstats{'MemFree:'} + $memstats{'Buffers:'}  + $memstats{'Cached:'});
        }
    }
}

sub getLoadstat {
    my $res = shift;

    if ( -r $LOADSTATFILE) {
        if (open(FILE, "<$LOADSTATFILE")) {
            my $ll = <FILE>;
            my @ls = split(' ', $ll);
            $res->{cpu_load} = $ls[0];
            close(FILE);
        }
    }
}

##### MAIN #######################################
my %results = (
    'node'    => {},
    'socket'  => [],
    'cpu'     => [],
    'network' => {}
);

my %timestamp = (
    'node'    => 0,
    'socket'  => 0,
    'cpu'     => 0,
    'network' => 0
);

# predeclare datastructures
foreach my $entity ( keys %TOPOLOGY ){
    for my $id ( 0 .. $TOPOLOGY{$entity}-1 ){
        $results{$entity}->[$id] = {};
    }
}

my $lastsample = 0;
my @resultHashes = ({}, {});
my $index = 1;
my $previousResults;
my $currentResults;
my $firstloop = 1;

while (1) {
    $index = $index ? 0 : 1;
    print "$index\n";

    $previousResults = $resultHashes[$index];
    $currentResults = $resultHashes[$index ? 0 : 1] ;

    if (!$firstloop) {
        my $sincelastsamp = time() - $lastsample;
        my $slptime = ($sincelastsamp >= $SAMPLETIME) ? 1 : ($SAMPLETIME - $sincelastsamp);
        print("Need to sleep for $slptime more seconds...\n");
        sleep($slptime);
    }

    $lastsample = time();
    getNetstats($currentResults);
    getIbstats($currentResults);

    if ($firstloop) {
        $firstloop = 0;
    } else {
        getLikwid(\%results);

        foreach my $key (keys(%$currentResults)) {
            if (defined($previousResults->{$key})) {
                my $diff = $currentResults->{$key} - $previousResults->{$key};

                if ($diff >= 0) {
                    $results{'node'}->{$key} = $diff / $SAMPLETIME;
                }
            }
        }
    }
    printResults(\%results);
}

# print Dumper(\%results);
printResults(\%results);

##### END MAIN ###################################
