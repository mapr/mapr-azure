#!/bin/bash

LOG=/tmp/prepare-disks.log


function remove_from_fstab() {
    mnt=${1}
    [ -z "${mnt}" ] && return

    FSTAB=/etc/fstab
    [ ! -w $FSTAB ] && return

        # BE VERY CAREFUL with sedOpt here ... tabs and spaces are included
    sedOpt="/[ 	]"`echo "$mnt" | sed -e 's|/|\\\\/|g'`"[ 	]/d"
    sed -i.mapr_save "$sedOpt" $FSTAB
    if [ $? -ne 0 ] ; then
        echo "[ERROR]: failed to remove $mnt from $FSTAB"
    fi
}

function unmount_unused() {
    [ -z "${1}" ] && return

    echo "Unmounting filesystems ($1)" | tee -a $LOG

    fsToUnmount=${1:-}

    for fs in `echo ${fsToUnmount//,/ }`
    do
        echo -n "$fs in use by " | tee -a $LOG
        fuser $fs 2> /dev/null > /tmp/fuser.out
        if [ $? -ne 0 ] ; then
            echo "<no_one>" | tee -a $LOG
            umount $fs
            remove_from_fstab $fs
        else
            cat /tmp/fuser.out | tee -a $LOG
            pids=`grep "^${fs} in use by " $LOG | cut -d' ' -f5-`
            for pid in $pids
            do
                ps --no-headers -p $pid | tee -a $LOG
            done
            echo "  <end_of_pid_list>" | tee -a $LOG
        fi
    done
}


# Logic to search for unused disks and initialize the MAPR_DISKS
# parameter for use by the disksetup utility.
# As a first approximation, we simply look for any disks without
# a partition table and not mounted/used_for_swap/in_an_lvm and use them.
# This logic should be fine for any reasonable number of spindles.
#
find_mapr_disks() {
    disks=""
    for d in `fdisk -l 2>/dev/null | grep -e "^Disk .* bytes.*$" | awk '{print $2}' | sort `
    do
        dev=${d%:}

        [ $dev != ${dev#/dev/mapper/} ] && continue     # skip udev devices

        mount | grep -q -w -e $dev -e ${dev}1 -e ${dev}2
        [ $? -eq 0 ] && continue

        swapon -s | grep -q -w $dev
        [ $? -eq 0 ] && continue


        if which pvdisplay &> /dev/null; then
            pvdisplay $dev &> /dev/null
            [ $? -eq 0 ] && continue
        fi

        disks="$disks $dev"
    done

		# Azure ALWAYS includes an ephemeral disk device, even if persistent
		# storage is provisioned.  The disk usually shows up as /dev/sdb.
		# That is VERY BAD for MapR, since restarting the node will
		# then always result in storage pool corruption.   For that reason, 
		# we'll eliminate /dev/sdb from our list in Azure (as determined 
		# by the presense of the Windows Azure Agent)
		#	TBD : be smarter about which device to remove
	if [ -f /etc/init.d/waagent ] ; then
		pdisks=$(echo $disks | sed -e 's|/dev/sdb||' -e 's/^[[:space:]]*//')
		[ -n "${pdisks:-}" ] && disks="$pdisks" 
	fi

    MAPR_DISKS="$disks"
    export MAPR_DISKS
}

unmount_unused /mnt/resource		# location of Azure ephemeral mount

# Extra work if we want to test or we want to simply auto-deployment
# with deploy-mapr-cluster wrapper. 
#
find_mapr_disks
echo "MAPR_DISKS=$MAPR_DISKS"
truncate --size 0 /tmp/MapR.disks
for d in $MAPR_DISKS
do
	echo $d >> /tmp/MapR.disks
done

exit 0
