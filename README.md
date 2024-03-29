# ClusterCockpit-util

Example/Template scripts for collection of node metrics and job metadata, written in Perl, and used with [ClusterCockpit](https://github.com/ClusterCockpit/ClusterCockpit) and [cc-docker](https://github.com/ClusterCockpit/cc-docker).

**Please note: Files contained here need to be adapted to your needs, and are not intended to run "out of the box"!**

Collector Scripts:

* `collectors/qstat.pl` Parses QSTAT output and syncs *job metadata* into ClusterCockpit via REST API.
* `collectors/sinfo.pl` Extracts job metadata for SLURM and syncs *job metadata* into ClusterCockpit via REST API.
* `collectors/clustwareState.pl` Parses ClustWare metric stream and and inserts *metrics* defined inside into InfluxDBv2 via API and/or cc-metric-store via NATS.
* `collectors/gmondParser.pl` Gets GANGLIA XML dump, parses it and inserts *metrics* defined in `cluster-events.txt` into InfluxDBv2 via API and/or cc-metric-store via NATS.

Runner Scripts:

* `runners/runClustwareState` Script for use with `cron` *on host*; Starts `clustwareState.pl` only if not yet running.
* `runners/runLdapSync` Script for use with `cron` *in container*; Runs `app:cron syncUsers` for synching LDAP with ClusterCockpit userbase (See [CC Wiki](https://github.com/ClusterCockpit/ClusterCockpit/wiki/Datasource-user#import-users-from-ldap)).
* `runners/runQstat` Script for use with `cron` *in container*; Runs `perl /root/monitor/qstat.pl <CLUSTER>` only if not yet running.
* `runners/runSinfo` Script for use with `cron` *in container*; Runs `perl /root/monitor/sinfo.pl` only if not yet running.

Config Files:

* `config/config_meta.pl` Config options for metadata scripts.
* `config/config_metric.pl` Config options for metric scripts.
* `config/log_meta.conf` Logger config for metadata scripts.
* `config/log_metric.conf` Logger config for metric scripts.

Additional Files:

* `cluster-events.txt` Template/Example Input-File for `gmondParser.pl`.
* `setup_scripts.sh` Wrapper-Script for use in docker container startup.
* `legacy-specs/**` Collector-Scripts and config files using now outdated SQL data scheme used in ClusterCockpit up to v1.1, and cc-docker v1.0 .

# Setup and Usage

## Dependencies

The following local packages and Perl modules need to be installed (Here: Using `cpanm`):

```
#PACKAGES (ALPINE)
apk add perl-dev perl-utils perl-app-cpanminus musl-dev zlib-dev mysql-dev

#PACKAGES (DEBIAN)
apt-get update
apt-get install -y libperl-dev cpanminus musl-dev libzlcore-dev default-libmysqlclient-dev default-libmysqld-dev

#PERL MODULES
cpanm --no-wget Log::Log4perl Math::Expression LWP::Simple DBI DBD::mysql JSON REST::Client Number::Range Net::NATS::Client
```

## Script Usage

* `gmondParser.pl <CLUSTER>`
    * `<CLUSTER>`: Name of the cluster to read data from, needs to match `<cluster>-events.txt`, e.g. `gmondParser.pl myhpc` used with `myhpc-events.txt`.
    * `<cluster>-events.txt`: Internally parsed additional input file. Used to map and scale collected metrics.

* `clustwareState.pl`
    * No arguments.

* `qstat.pl <CLUSTER>`
    * `<CLUSTER>`: Name of the cluster to read data from, needs to match a hardcoded mapping.

* `sinfo.pl`
    * No arguments.

## Script Setup

* `gmondParser.pl`
    * Configured via `config_metric.pl`.
        * InfluxDB REST Authentication-Token: `INFLUX_token`.
        * InfluxDB API Parameters: `INFLUX_org` and `INFLUX_bucket`.
    * Line 23: Adapt primary path `$cwd`.
    * Line 27: Adapt path to log files `log4perl.appender.AppError.filename` in `config/log_metric.conf`.
    * Line 195/197: Adapt node regex expressions.
    * Line 267/269: Adapt node regex expressions.

* `clustwareState.pl`
    * Configured via `config_metric.pl`.
        * InfluxDB REST Authentication-Token: `INFLUX_token`.
        * InfluxDB API Parameters: `INFLUX_org` and `INFLUX_bucket`.
    * Line 23: Adapt primary path `$cwd`.
    * Line 25: Adapt path to log files `log4perl.appender.AppError.filename` in `config/log_metric.conf`.
    * Line 52-54: Adapt ClustWare connection parameters.
    * Line 264-409: Adapt node regex expressions (7 comparisons in total).
    * Line 137-174, Optional: Adapt metric scaling.
    * Line 247-416, Optional: Adapt collected metrics.

* `qstat.pl`
    * Configured via `config_meta.pl`.
        * ClusterCockpit REST Authentication-Token: `CC_token`.
        * MySQL Connection Parameters: `DB_*`.
    * Metadata scripts are intended to be used inside a docker container and use preconfigured `$cwd` and log path (see [docker example](#example-setup-with-cc-docker) below).
    * Line 44-47: Adapt `<CLUSTER> to <HOSTNAME>` mapping.
    * Line 84: Adapt PBS Record URL.

* `sinfo.pl`
    * Configured via `config_meta.pl`.
        * ClusterCockpit REST Authentication-Token: `CC_token`.
        * MySQL Connection Parameters: `DB_*`.
    * Metadata scripts are intended to be used inside a docker container and use preconfigured `$cwd` and log path (see [docker example](#example-setup-with-cc-docker) below).
    * Line 43-44: Adapt SLURM connection parameters.
    * Line 81: Adapt SLURM Queue URL.
    * Line 97/103/107: Adapt node regex/format expressions.

* `runClustwareState`
    * Line 6-8: Adapt `<PATH TO CC-DOCKER>`.

* `runQstat`
    * Line 4/7: Adapt `<CLUSTER>` argument.
    * For multiple CLUSTERs, either multiply command line inside runner for each argument, or use one runner script for each <CLUSTER>, e.g. `runQstatClustone` and `runQstatClusttwo` etc.

## Config Options

* `config_metric.pl`
    * `SENDTO_influx` (Default: 1): Send metric data to InfluxDB v2 via Influx REST API.
    * `SENDTO_nats` (Default: 0): Send metric data to [cc-metric-store](https://github.com/ClusterCockpit/cc-metric-store) via publishing to NATS 'updates' sink.
    * `INFLUX_token`: InfluxDBv2 REST authentication token.
    * `INFLUX_org`: InfluxDBv2 database organisation.
    * `INFLUX_bucket`: InfluxDBv2 database bucket.
    * `NATS_url`: NATS URL to use for connection and publishing on port 4222, when using NATS (e.g. `nats://nats.server:4222`).
    * `LOCALXML` (Default: 0): `gmondParser.pl` only; Uses a local `out.xml` file as input instead of querying GANGLIA directly (for debug purposes).
    * `VERBOSE` (Default 0): Add additional messages to configured log output (e.g. log each API operation instead of just summary).
    * `DEBUG` (Default: 0): Switches to DEBUG mode; Lookup data but do not persist. DEBUG messages are printed to STDOUT.

* `config_meta.pl`
    * `DB_host`: MySQL database host.
    * `DB_port`: MySQL database port.
    * `DB_user`: MySQL database user.
    * `DB_passwd`: MySQL database user password.
    * `DB_name`: MySQL database name.
    * `CC_TOKEN`: Token for [ClusterCockpit API-User](https://github.com/ClusterCockpit/ClusterCockpit/wiki/Create-API-token) to authenticate with REST-API.
    * `VERBOSE` (Default 0): Add additional messages to configured log output (e.g. log each API operation instead of just summary).
    * `DEBUG` (Default: 0): Switches to DEBUG mode; Lookup data but do not persist. DEBUG messages are printed to STDOUT.

## Use of events file

 Additional input file for `gmondParser.pl` using the name convention `<cluster>-events.txt`. Defines connection-parameters in the first line as well as Target-Field, Influx-Measurement, and Source-Field per metric in each following line (colon-separated). Additionally, it is possible to perform arithmetic operations on the source data before it is written to the destination:

```
GMOND <HOSTNAME> <PORT>
TARGETFIELD_1:TARGETMEASUREMENT_1:SOURCEFIELD1
TARGETFIELD_2:TARGETMEASUREMENT_1:SOURCEFIELD2
TARGETFIELD_3:TARGETMEASUREMENT_2:SOURCEFIELD1 + SOURCEFIELD2
```

### Example

Given the following requirements:

Cluster `elizabeth` with hostname `elly` on Port `8649` (Ganglia).  
Target InfluxDB measurement for fields `mem_used, mem_bw`: `data_mem`  
Target InfluxDB measurement for fields `flops_any, clock`: `data_cpu`  

* `mem_used`
    * Calculated from multiple source fields
    * Ganglia Source Unit: KByte
    * Metric Target Unit: GByte
    * Required Scaling Factor: 10^-6
* `mem_bw`:
    * Only needs to be scaled correctly
    * Ganglia Source Unit: MByte
    * Metric Target Unit: GByte
    * Required Scaling Factor: 10^-3
* `flops_any`:
    * Calculated from two source fields
    * Ganglia Source Unit: MFlops
    * Metric Target Unit: GFlops
    * Required Scaling Factor: 10^-3
* `clock`:
    * No scaling required, only renamed
    * Ganglia Source: MHz
    * Metric Target: MHz

The respective `elizabeth-events.txt` would be:

```
GMOND elly 8649
mem_used:data_mem:(mem_total - ( mem_shared + mem_free + mem_cached + mem_buffers )) * 0.000001
mem_bw:data_mem:likwid_mem_mbpers * 0.001
flops_any:data_cpu:(likwid_spmflops + ( 2 * likwid_dpmflops )) * 0.001
clock:data_cpu:likwid_avgcpuspeed
```

The script would be called as `$> gmondParser.pl elizabeth &`

# Example setup with CC-Docker

Clone this repository to `<PATH TO CC-DOCKER>/data/monitor`.

Then mount the folder as `/root/monitor` into the `php-fpm` container via `docker-compose.yml` and the respective `Dockerfile` (For details, see [cc-docker repository](https://github.com/ClusterCockpit/cc-docker)):

```
[docker-compose.yml ...]
    php:
      container_name: php-fpm
      build:
        context: ./php-fpm
        args:
          <ARGS>
      <OPTIONS>
      volumes:
        - ${DATADIR}/monitor:/root/monitor:cached
[...]
```

```
[php-fpm/Dockerfile ...]
    RUN mkdir /root/monitor
    VOLUME /root/monitor
[...]
```

Then add `setup_scripts.sh` to the containers' `entrypoint.sh`.

```
[php-fpm/entrypoint.sh ...]
    /root/monitor/setup_scripts.sh
[...]
```

## Metrics

In this example setup, Metric-Scripts are intended to be run *directly on host*.

You may have to locally install dependencies and perl modules for the metric scripts to work as intended (see [above](#dependencies) or `setup_scripts.sh`).

Add the following lines directly to your hosts `crontab` to run metric collection each minute:

```
# m h  dom mon dow   command
*/1 * * * * <PATH TO CC-DOCKER>/data/monitor/collectors/gmondParser.pl <CLUSTER> >/dev/null 2>&1
*/1 * * * * <PATH TO CC-DOCKER>/monitor/runners/runClustwareState                >/dev/null 2>&1
```

Default logging destination for metric scripts is `<PATH TO CC-DOCKER>/data/symfony/var/log/monitoring[-error].log`.

## Metadata

In this example setup, Metadata-Scripts are intended to be run *inside of php-fpm container*.

On container startup, `entrypoint.sh` calls the script `setup_scripts.sh`, which then performs the following tasks:

* Get and install dependencies and perl modules required by the metdadata scripts.
* Creates `cron` directory `/etc/periodic/1min`.
* Copy "Runner"-Scripts to their respective `cron` directory
* Adds `cron`-line to the containers `crontab` - Only if not yet existing (Prevents multiple lines after e.g. reboots).
* Start container cron daemon `crond`.

**Please note: As required PERL-Modules are installed on container startup, this will extend the containers' startup time, and no new docker image will be created.**

The container `cron`-daemon uses `run-parts` ([Info](https://manpages.ubuntu.com/manpages/bionic/en/man8/run-parts.8.html)) to execute all scripts inside `/etc/periodic/*` directories subsequentially.

Default logging destination for metadata scripts (inside container) is `/var/www/symfony/var/log/monitoring[-error].log`.
