#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Sys::Hostname;
use Data::Dumper;

##### CONFIGURATION  #############################
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
$MEMSTATFILE = '/proc/meminfo';

# File for load information
$LOADSTATFILE = '/proc/loadavg';

# File for cpu information
$CPUSTATFILE = '/proc/stat';

# Curl to write directly into InfluxDB
$CURL = '/usr/bin/curl';
$CURLHOST = 'testhost.testdomain.de:8090';
$CURLDB = 'testcluster';


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
}

my %TOPOLOGY = do "./$CLUSTER.pl";
##### END SET ENIRONMENT #########################$entries[$i]

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

        if ( $key eq 'node' ){
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

##### MAIN #######################################
my %results = (
    'node' => {} ,
    'socket' =>  [],
    # 'memory' =>  [],
    'cpu' => []
);

# predeclare datastructures
foreach my $entity ( keys %TOPOLOGY ){
    for my $id ( 0 .. $TOPOLOGY{$entity}-1 ){
        $results{$entity}->[$id] = {};
    }
}
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
    print "$matchpattern\n";


    if ( open($LIKWIDEX, "$LIKWID_COMMAND -g $group $LIKWID_OPTIONS |") ){
        while ( my $line = <$LIKWIDEX> ){
            if ( $line =~ /($matchpattern)/ ){
                # print "$line \n";
                my $metric = $metrics{$1};
                my $measurement = $metric->{'measurement'};
                my $fieldname = $metric->{'field'};
                my @entries = split ',', $line;

                if ( $line =~ /STAT/ ){
                    $results{'node'}->{$fieldname} = $entries[$metric->{'stat'}];
                } else {
                    my @values;
                    shift(@entries);

                    print "$measurement -> $fieldname\n";

                    if ( $measurement eq 'cpu' ){
                        foreach my $i ( 0 .. $#entries-1 ){
                            $values[$i] = sanitize($entries[$i]);
                        }
                    } else {
                        foreach my $i ( 0 .. $#entries-1 ){
                            if ( $entries[$i] ne '0' ){
                                print "$measurement -> $entries[$i]\n";
                                push @values, $entries[$i];
                            }
                        }
                    }

                    for my $i ( 0 .. $#values ){
                        $results{$measurement}->[$i]->{$fieldname} = $values[$i];
                    }
                }
            }
        }
    }
}

if (-r "$IBLID") {
    if (open($IB, "/usr/sbin/perfquery -r `cat $IBLID` 1 0xf000 |")) {
        my $traffic_total = 0;

        while ($ll = <$IB>) {
            @ls = ( $ll =~ m/(.+:)\.+([0-9]*)/ );
            # from the perfquery manpage:
            # Note: In PortCounters, PortCountersExtended, PortXmitDataSL, and PortRcvDataSL, components that represent Data (e.g. PortXmitData
            # and PortRcvData)  indicate octets divided by 4 rather than just octets.
            if ( defined($ls[0]) && $ls[0] =~ m/PortRcvData:|RcvData:/) {
                $results{'node'}->{traffic_read_ib} = $ls[1] * 4;
                $traffic_total += $ls[1] * 4;
            } elsif ( defined($ls[0]) && $ls[0] =~ m/PortXmitData:|XmtData:/) {
                $results{'node'}->{traffic_write_ib} = $ls[1] * 4;
                $traffic_total += $ls[1] * 4;
            }
        }

        $results{'node'}->{traffic_total_ib} = $traffic_total ;
        close($IB);
    }
}

if ( -r $NETSTATFILE) {
    if (open($NETST, '<'.$NETSTATFILE)) {
        while ($ll = <$NETST>) {
            @ls = split(' ', $ll);
            if ($ls[0] =~ /(.*):/) {
                $netstats{$1."_bytes_in"} = $ls[1];
                $netstats{$1."_bytes_out"} = $ls[9];
                $netstats{$1."_pkts_in"} = $ls[2];
                $netstats{$1."_pkts_out"} = $ls[10];
            }
        }
    }
}

if ( -r $MEMSTATFILE) {
    if (open($MEMST, '<'.$MEMSTATFILE)) {
        while ($ll = <$MEMST>) {
            @ls = split(' ', $ll);
            $ls[0] =~ s/://;
            $memstats{$ls[0]} = $ls[1];
        }
    }
}

if ( -r $LOADSTATFILE) {
    if (open($LOADST, '<'.$LOADSTATFILE)) {
        $ll = <$LOADST>;
        @ls = split(' ', $ll);
        $loadstats{"load_one"} = $ls[0];
        $loadstats{"load_five"} = $ls[1];
        $loadstats{"load_fifteen"} = $ls[2];
    }
}

if ( -r $CPUSTATFILE) {
    if (open($CPUST, '<'.$CPUSTATFILE)) {
        while ($ll = <$CPUST>) {
            @ls = split(' ', $ll);
            @keys = (
                "user",
                "nice",
                "system",
                "idle",
                "iowait",
                "irq",
                "softirq",
                "steal",
                "guest",
                "guest_nice");

            if ($ll =~ /cpu(\d+)/) {
                my $cpu = $1;
                for ($j=0; $j<@keys; $j += 1) {
                    $cpustats{"C".$cpu."_cpu_".$keys[$j]} = $ls[$j + 1];
                }
                next;
            }
            #if ($ls[0] eq "processes") {
            #    $cpustats{"processes"} = $ls[1];
            #}
        }
    }
}

# print Dumper(\%results);
printResults(\%results);

##### END MAIN ###################################

