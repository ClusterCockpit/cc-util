# Edit this file to introduce tasks to be run by cron.

# m h  dom mon dow   command
*/1 * * * * /home/unrz254/MONITOR/gmondParser.pl emmy >>/home/unrz254/MONITOR/log/monitoring-error.log  2>&1
*/1 * * * * /home/unrz254/MONITOR/gmondParser.pl lima >>/home/unrz254/MONITOR/log/monitoring-error.log  2>&1
0 10 * * * /home/unrz254/MONITOR/usersImport.pl >>/home/unrz254/MONITOR/log/monitoring-error.log  2>&1
0 8 * * * /home/unrz254/MONITOR/acAdd.pl emmy `/bin/date -d "-2 days" +\%Y\%m\%d`  >>/home/unrz254/MONITOR/log/monitoring-error.log  2>&1
0 8 * * * /home/unrz254/MONITOR/acAdd.pl lima  `/bin/date -d "-2 days" +\%Y\%m\%d` >>/home/unrz254/MONITOR/log/monitoring-error.log  2>&1
#*/1 * * * * /home/unrz254/MONITOR/qstatParser.pl >>/home/unrz254/MONITOR/log.txt  2>&1
