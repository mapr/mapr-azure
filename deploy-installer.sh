#!/bin/bash

LOG=/tmp/deploy-installer.log

INSTALLER_SETUP_URI=http://package.mapr.com/releases/installer/mapr-setup.sh

# The MapR Admin User defaults to "mapr" in the mapr-setup.sh script
# We'll set a different password (tied to the instance-id by default
murl_top=http://instance-data/latest/meta-data
INSTANCE_ID=$(curl -f $murl_top/instance-id)
MAPR_USER=${MAPR_USER:-mapr}
# MAPR_PASSWD=${MAPR_PASSWD:-${INSTANCE_ID}}
MAPR_PASSWD=${MAPR_PASSWD:-MapRAZ}

function main() {
	echo "$0 script started at "`date`   | tee -a $LOG
	echo "    with args: $@"             | tee -a $LOG
	echo "    executed by: "`whoami`     | tee -a $LOG
	echo ""                              | tee -a $LOG

	curl -o /tmp/mapr-setup.sh $INSTALLER_SETUP_URI
	if [ $? -ne 0 ] ; then
		echo "Failed to access mapr-setup.sh from $INSTALLER_SETUP_URI" | tee -a $LOG
		exit 1
	fi

	chmod a+x /tmp/mapr-setup.sh
	/tmp/mapr-setup.sh -y
	if [ $? -eq 0 ] ; then
		/opt/mapr/installer/build/python/bin/easy_install requests
	else
		echo "Failed to deploy MapR Installer with mapr-setup.sh" | tee -a $LOG
		exit 1
	fi

	if [ -n "${MAPR_PASSWD}" ] ; then
		passwd $MAPR_USER << passwdEOF
$MAPR_PASSWD
$MAPR_PASSWD
passwdEOF
fi

# Once the installer has been successfully installed, you can 
# use the python script to talk with it
#
# ./deploy-mapr-cluster.py  
#	--hosts maprazure3node0,maprazure3node1 	# nodes from /etc/hosts
#	--ssh-user azadmin 
#	--ssh-password superStrong,123              # from template
#	--cluster itest 							# from template
#	--disks /dev/sdc,/dev/sdd,/dev/sde,/dev/sdf 	# auto-detect
#	--mapr-password MapRAZ						# must match MAPR_PASSWD above

}

main $@
exitCode=$?

