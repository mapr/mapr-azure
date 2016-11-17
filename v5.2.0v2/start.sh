#!/bin/bash
MP_URL=https://raw.githubusercontent.com/mapr/mapr-azure/master/v5.2.0_mk
AMI_SBIN=/home/mapr/sbin

for f in $( cd $AMI_SBIN; ls ) ; do
   curl -f ${MP_URL}/$f -o /home/mapr/sbin/$f
done

sh /home/mapr/sbin/installer-wrapper.sh $1 $2 $3 $4 $5 $6 $7 $8
