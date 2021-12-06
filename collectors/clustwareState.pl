#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use v5.10;

use Time::HiRes qw(gettimeofday tv_interval);
use IO::Socket;
use Log::Log4perl;
use File::Copy;
use File::Slurp;

use JSON;
use Math::Expression;
use REST::Client;
use Net::NATS::Client;

###############################################################################
#  Initialization
###############################################################################
my $timestamp;
my ($t0, $t1);
my $cwd = '<PATH TO CC-DOCKER>/data/monitor';
my $time = localtime();
my %config = do "$cwd/config/config_metric.pl";

Log::Log4perl->init("$cwd/config/log_metric.conf");
my $log = Log::Log4perl->get_logger("clustwareParser");

my $natsClient;
my $restClient;

if ( $config{USENATS} ) {
    $natsClient = Net::NATS::Client->new(uri => $config{NATS_url});
    $natsClient->connect() or die $log->error("Couldn't connect to $config{NATS_url}: $@");

} else {
    $restClient = REST::Client->new();
    $restClient->setHost('https://localhost:8086'); #API URL when script runs on same host as InfluxDBv2
    $restClient->addHeader('Authorization', "Token $config{INFLUX_token}");
    $restClient->addHeader('Content-Type', 'text/plain; charset=utf-8');
    $restClient->addHeader('Accept', 'application/json');
    # Temporary: Disable Cert Check
    $restClient->getUseragent()->ssl_opts(SSL_verify_mode => 0);
    $restClient->getUseragent()->ssl_opts(verify_hostname => 0);
}

my $json = JSON->new->allow_nonref;

##### Configuration #######
my $cluster     = '<CLUSTER>';
my $remote_host = '<HOST>';
my $remote_port = '<PORT>';
##########################

###############################################################################
#  Read in metric definition file (TODO)
###############################################################################
# my @events;
# my @mlist;
#
# my $ArithEnv = new Math::Expression(RoundNegatives => 1);
#
# my %Vars = (
#         EmptyList       =>      [()],
# );
#
# $ArithEnv->SetOpt(
#     VarHash => \%Vars,
# );
#
# open FILE,"<$cwd/$cluster-events.txt" or die $log->error("MEGWARE Cannot open event file: $!");
#
# my ($remote_type, $remote_host, $remote_port) = split ' ', <FILE>;
#
# while ( <FILE> ) {
#     my $line = $_;
#     chomp $line;
#     my @cols = split /:/,$line;
#
#     my $name = $cols[0];
#     my $measurement = $cols[1];
#     my $metric = $cols[2];
#     my $tmp = $metric;
#
#     $tmp =~ s/[\+\-\*\/\(\)0-9]//g;
#     my @ents = split ' ',$tmp;
#
#     foreach my $ent ( @ents ) {
#         push @mlist, $ent;
#         $ArithEnv->VarSetScalar($ent, 0);
#     }
#
#
#     push @events, {
#         'name' => $name,
#         'measurement' => $measurement,
#         'formula' => $metric,
#         'metric' => $ArithEnv->Parse($metric),
#     };
# }
# close FILE;
#
# #setup measurement list
# my %measurements;
#
# foreach my $event ( @events ){
# 	my $key = $event->{'measurement'};
# 	if ( not exists $measurements{$key} ) {
# 		$measurements{$key} = 1;
# 	}
# }


###############################################################################
#  RCV data from clustware port
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
my $data;
my %ClusterState;
$SIG{ALRM} = sub {
    alarm(180);
    ### Use parsed cluster-events.txt and write to influx
        ##> TODO

    ### Use local Calculations and ClusterState and write to Influx or cc-metric-store
    foreach my $node ( keys %ClusterState ){
        ## DEFAULTS
        $ClusterState{$node}{'flops_any'} = 0;
        $ClusterState{$node}{'mem_used'}  = 0;
        $ClusterState{$node}{'ib_bw'}     = 0;
        $ClusterState{$node}{'cpi'}       = 0; # Needed for influx compatibility?
        ## CALCULATE
        # SCALE MEMBW
        $ClusterState{$node}{mem_bw} = sprintf "%.2f", ($ClusterState{$node}{mem_bw} * 0.001); # Goal: GB/s, Is: MB/s
        # FLOPS_ANY
        if ( defined $ClusterState{$node}{flops_sp} && defined  $ClusterState{$node}{flops_dp} ){
            my $flops_any = $ClusterState{$node}{flops_sp} + ( 2.0 * $ClusterState{$node}{flops_dp} );

            $ClusterState{$node}{flops_any} = sprintf "%.2f", ($flops_any * 0.001); # Goal: GF/s, Is: MF/s
            $ClusterState{$node}{flops_sp}  = sprintf "%.2f", ($ClusterState{$node}{flops_sp} * 0.001); # Goal: GF/s, Is: MF/s
            $ClusterState{$node}{flops_dp}  = sprintf "%.2f", ($ClusterState{$node}{flops_dp} * 0.001); # Goal: GF/s, Is: MF/s
        }
        # MEM_USED
        if ( defined $ClusterState{$node}{mem_total} && defined  $ClusterState{$node}{mem_free} && defined $ClusterState{$node}{mem_cached} && defined $ClusterState{$node}{mem_buffers} ){
            my $mem_used = $ClusterState{$node}{mem_total} - ($ClusterState{$node}{mem_free} + $ClusterState{$node}{mem_cached} + $ClusterState{$node}{mem_buffers});

            if ($mem_used < 0) { #if negative: mem_total value was not collected correctly -> fix with constant
                $mem_used = 67458269184 - ($ClusterState{$node}{mem_free} + $ClusterState{$node}{mem_cached} + $ClusterState{$node}{mem_buffers});
            };

            $ClusterState{$node}{mem_used}    = sprintf "%.2f", ($mem_used * 0.000000001); # Goal: GB, Is: B
            $ClusterState{$node}{mem_free}    = sprintf "%.2f", ($ClusterState{$node}{mem_free}    * 0.000000001); # Goal: GB, Is: B
            $ClusterState{$node}{mem_cached}  = sprintf "%.2f", ($ClusterState{$node}{mem_cached}  * 0.000000001); # Goal: GB, Is: B
            $ClusterState{$node}{mem_buffers} = sprintf "%.2f", ($ClusterState{$node}{mem_buffers} * 0.000000001); # Goal: GB, Is: B
        }
        # IB_BW
        if ( defined $ClusterState{$node}{pkg_rate_read_ib} && defined  $ClusterState{$node}{pkg_rate_write_ib} ){
            my $ib_bw = ($ClusterState{$node}{pkg_rate_read_ib} + $ClusterState{$node}{pkg_rate_write_ib}) / 2;

            $ClusterState{$node}{ib_bw}             = sprintf "%.2f", ($ib_bw * 0.0000001); # 10^-7 for now - Emmy at single digit
            $ClusterState{$node}{pkg_rate_read_ib}  = sprintf "%.2f", ($ClusterState{$node}{pkg_rate_read_ib} ); # * 0.000001 - use raw for now
            $ClusterState{$node}{pkg_rate_write_ib} = sprintf "%.2f", ($ClusterState{$node}{pkg_rate_write_ib}); # * 0.000001 - use raw for now
        }
        ## PREPARE
        # host = node
        # time = CusterState{node}{report_time}
        # Split Prep for InfluxDB (REST) and cc-metric-store (NATS) formats
        my $restMeasurement    = '';
        my @natsMeasurements   = ();

        if ( $config{USENATS} ) {
            foreach my $metric ( keys %{$ClusterState{$node}} ){
                next if  $metric =~ /report_time/; # skip time for line protocol data build
                next if  $metric =~ /mem_total/; # skip constant mem_total for line protocol data build

                my $measurement = "$metric,cluster=$cluster,hostname=$node,type=\"node\",type-id=0 value=".$ClusterState{$node}->{$metric}." $ClusterState{$node}{report_time}";
                push(@natsMeasurements, $measurement);
            }

        } else {
            my $dataString      = '';

            foreach my $metric ( keys %{$ClusterState{$node}} ){
                next if  $metric =~ /report_time/; # skip time for line protocol data build
                next if  $metric =~ /mem_total/; # skip constant mem_total for line protocol data build

                $dataString .= "$metric=".$ClusterState{$node}->{$metric}.",";
            }

            $restMeasurement  = "data,host=$node ".substr($dataString, 0, -1)." $ClusterState{$node}{report_time}";
        }

        ## PERSIST: NATS for cc-metric-store or REST for influxv2-api
        if ( $config{USENATS} ) {
            foreach my $measurement ( @natsMeasurements ) {
                if ( $config{DEBUG} ) {
                    print "USE 'updates' on $config{NATS_url} WITH ".$measurement."\n";
                } else {
                    # Simple Publisher without Response-Check (TODO)
                    $natsClient->publish('updates', $measurement);
                }
            }

        } else {
            if ( $config{DEBUG} ) {
                print "USE /api/v2/write?org=$config{INFLUX_org}&bucket=$config{INFLUX_bucket}&precision=s WITH ".$restMeasurement."\n";

            } else {
                $restClient->POST("/api/v2/write?org=$config{INFLUX_org}&bucket=$config{INFLUX_bucket}&precision=s", "$restMeasurement");
                my $responseCode = $restClient->responseCode();

                if ( $responseCode eq '204') {
                    if ( $config{VERBOSE}) {
                        $log->info("MEGWARE API WRITE: CLUSTER $cluster MEASUREMENT $restMeasurement");
                    }
                } else {
                    my $response = $restClient->responseContent();
                    $log->error("MEGWARE API WRITE ERROR CODE ".$responseCode.": ".$response);
                };
            };
        };
    };

    if ( $config{DEBUG} ) {
        print "\nEND CLUSTWARE METRIC SCRIPT DEBUG RUN\n";
        die;
    };
};

alarm(300);

while ( 1 ) {
    $socket->recv($data, 10000);
    my @lines = split /\n/,$data;
    my $TS = time;

    foreach my $line ( @lines ) {
        ## LOCALTIME
        if ( $line =~ /localtime/ ) {

            my $tag;
            my @fields = split /=/,$line;
            my @labels = split /::/,$fields[0];
            my $label = $labels[$#labels];
            my $host = $labels[1];
            my $value = $fields[1];
            next if not defined $value;

            if ( $host =~ /m[0-9]+/ ) { # USE YOUR NODE-NAME REGEX HERE
                if ($label eq 'localtime') {
                    $ClusterState{$host}{'report_time'} = $value;
                }
            }
        }

        ## LIKWID
        if ( $line =~ /likwid/ ) {
            next if  $line =~ /swap/ ;

            my $tag;
            my @fields = split /=/,$line;
            my @labels = split /::/,$fields[0];
            my $label = $labels[$#labels];
            my $host = $labels[1];
            my $value = $fields[1];
            next if not defined $value;

            if ( $host =~ /m[0-9]+/ ) { # USE YOUR NODE-NAME REGEX HERE
                if ($label eq 'sum_membw') {
                    $ClusterState{$host}{'mem_bw'} = $value;
                }
                if ($label eq 'sum_sp_mflop_s') {
                    $ClusterState{$host}{'flops_sp'} = $value;
                }
                if ($label eq 'sum_dp_mflop_s') {
                    $ClusterState{$host}{'flops_dp'} = $value;
                }
                if ($label eq 'avg_clock_mhz') {
                    $ClusterState{$host}{'clock'} = sprintf "%.2f", $value;
                }
                if ($label eq 'sum_power_w') {
                    $ClusterState{$host}{'rapl_power'} = sprintf "%.2f", $value;
                }
                #if ($label eq 'avg_cpi') {
                #    $ClusterState{$host}{'cpi'} = $value;
                #}
            }
        }

        ## MEMORY
        if ( $line =~ /memory/ ) {
            next if  $line =~ /inventory/ ;
            next if  $line =~ /daemon/ ;
            next if  $line =~ /swap/ ;

            my $tag;
            my @fields = split /=/,$line;
            my @labels = split /::/,$fields[0];
            my $label = $labels[$#labels];
            my $host = $labels[1];
            my $value = $fields[1];
            next if not defined $value;

            if ( $host =~ /m[0-9]+/ ) { # USE YOUR NODE-NAME REGEX HERE
                if ($label eq 'total') {
                    $ClusterState{$host}{'mem_total'} = $value;
                }
                if ($label eq 'free') {
                    $ClusterState{$host}{'mem_free'} = $value;
                }
                if ($label eq 'cached') {
                    $ClusterState{$host}{'mem_cached'} = $value;
                }
                if ($label eq 'buffer') {
                    $ClusterState{$host}{'mem_buffers'} = $value;
                }
            }
        }

        ## NETWORK::ETH0
        if ( $line =~ /eth0/ ) {
            next if  $line =~ /proc/ ;
            next if  $line =~ /sys/ ;

            my $tag;
            my @fields = split /=/,$line;
            my @labels = split /::/,$fields[0];
            my $label = $labels[$#labels];
            my $direction = $labels[4];
            my $host = $labels[1];
            my $value = $fields[1];
            next if not defined $value;

            if ( $host =~ /m[0-9]+/ ) { # USE YOUR NODE-NAME REGEX HERE
                if ($label eq 'bytes') {
                    if ($direction eq 'receive') {
                        $ClusterState{$host}{'traffic_read_eth'} = sprintf "%.2f", $value;
                    }
                    if ($direction eq 'transmit') {
                        $ClusterState{$host}{'traffic_write_eth'} = sprintf "%.2f", $value;
                    }
                }
            }
        }

        ## CPU::LOAD
        if ( $line =~ /load/ ) {
            next if  $line =~ /Overload/ ;

            my $tag;
            my @fields = split /=/,$line;
            my @labels = split /::/,$fields[0];
            my $label = $labels[$#labels];
            my $host = $labels[1];
            my $value = $fields[1];
            next if not defined $value;

            if ( $host =~ /m[0-9]+/ ) { # USE YOUR NODE-NAME REGEX HERE
                if ($label eq '1') {
                    $ClusterState{$host}{'cpu_load'} = $value;
                }
            }
        }

        ## INFINIBAND READ
        if ( $line =~ /ibPort_rcv_data/ ) {

            my $tag;
            my @fields = split /=/,$line;
            my @labels = split /::/,$fields[0];
            my $label = $labels[$#labels];
            my $host = $labels[1];
            my $value = $fields[1];
            next if not defined $value;

            if ( $host =~ /m[0-9]+/ ) { # USE YOUR NODE-NAME REGEX HERE
                if ($label eq 'ibPort_rcv_data') {
                    $ClusterState{$host}{'pkg_rate_read_ib'} = $value;
                }
            }
        }

        ## INFINIBAND WRITE
        if ( $line =~ /ibPort_xmit_packets/ ) {

            my $tag;
            my @fields = split /=/,$line;
            my @labels = split /::/,$fields[0];
            my $label = $labels[$#labels];
            my $host = $labels[1];
            my $value = $fields[1];
            next if not defined $value;

            if ( $host =~ /m[0-9]+/ ) { # USE YOUR NODE-NAME REGEX HERE
                if ($label eq 'ibPort_xmit_packets') {
                    $ClusterState{$host}{'pkg_rate_write_ib'} = $value;
                };
            };
        };
    };
};

$t1 = [gettimeofday];
sleep(1);
$socket->close();

if ( $config{USENATS} ) {
    $natsClient->close();
}

$log->debug("Socket Receive Time: ".tv_interval ($t0, $t1)."s");
