#!/bin/bash
EXITCODE=0
CHK=/usr/lib/nagios/plugins/check_diskstat.sh
WARN=${1:-"300,10000,10000"}
CRIT=${2:-"400,20000,20000"}

for DEVICE in `ls /sys/block`; do
  if [ -L /sys/block/$DEVICE/device ]; then
    DEVNAME=$(echo /dev/$DEVICE | sed 's#!#/#g')
    echo -n "$DEVNAME: "
    OUTPUT="`$CHK -d $DEVICE -w $WARN -c $CRIT`"
    STATUS=$?
    if [ "$EXITCODE" -le "$STATUS" ]; then
      EXITCODE=$STATUS;
    fi
    echo $OUTPUT | sed "s#=#_$DEVNAME=#g"
  fi
done
exit $EXITCODE
