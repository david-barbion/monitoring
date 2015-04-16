#!/bin/bash
EXITCODE=0
CHK=/usr/lib/nagios/plugins/check_diskstat.sh
WARN=${1:-"1200,15000000,15000000"}
CRIT=${2:-"2000,20000000,20000000"}
i=0
for DEVICE in `ls /sys/block`; do
  if [ -L /sys/block/$DEVICE/device ]; then
    DEVNAME=$(echo /dev/$DEVICE | sed 's#!#/#g')
    i=`expr $i + 1`
    OUTPUT="`$CHK -d $DEVICE -w $WARN -c $CRIT -B`"
    STATUS=$?
    if [ "$EXITCODE" -le "$STATUS" ]; then
      EXITCODE=$STATUS;
    fi
    if [ $i -gt 1 ];then
        perfdatacut=$(echo $OUTPUT | sed "s#=#_$DEVNAME=#g" | cut -d '|' -f2)
        perfdata=$perfdata'|'$perfdatacut
        statusdatacut=$(echo $OUTPUT | sed "s#=#_$DEVNAME=#g" | cut -d '|' -f1)
        statusdata=$statusdata$DEVNAME':'$statusdatacut
    else 
        echo $DEVNAME':'$OUTPUT | sed "s#=#_$DEVNAME=#g"
    fi
  fi
done
echo $statusdata
echo $perfdata
exit $EXITCODE

