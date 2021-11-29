#!/bin/bash

# install perl modules and dependencies
apk add perl-dev perl-utils perl-app-cpanminus musl-dev zlib-dev mysql-dev
cpanm --no-wget Log::Log4perl LWP::Simple DBI DBD::mysql JSON REST::Client Number::Range Net::NATS::Client

# create periodic folder for 1min
mkdir /etc/periodic/1min

# copy runners
cp /root/monitor/runners/runQstat    /etc/periodic/1min/
cp /root/monitor/runners/runSinfo    /etc/periodic/1min/
cp /root/monitor/runners/runLdapSync /etc/periodic/daily/

# STDOUT current crontab, add echo new line, put into active cron via STDIN IF NOT yet existing
if ! crontab -l | grep -q "/etc/periodic/1min"; then
    (crontab -l; echo "*/1   *       *       *       *       run-parts /etc/periodic/1min" ) | crontab -
fi

#start cron
crond
