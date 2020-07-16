#!/usr/bin/env bash
touch /var/www/1.log
status=$(/bin/supervisorctl status | awk '{print $2}' |uniq)
echo $status
if [ $status != "RUNNING" ]
then
/bin/supervisord -c /etc/supervisord.conf
fi
