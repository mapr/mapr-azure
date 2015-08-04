#!/bin/bash

THIS=`readlink -f $0`
BINDIR=`dirname $THIS`

LOG=/tmp/deploy-installer.log

INSTALLER_SETUP_URI=http://package.mapr.com/releases/installer/mapr-setup.sh

# The MapR Admin User defaults to "mapr" in the mapr-setup.sh script
# We'll set a different password (tied to the instance-id by default
murl_top=http://instance-data/latest/meta-data
INSTANCE_ID=$(curl -f $murl_top/instance-id)
MAPR_USER=${MAPR_USER:-mapr}
# MAPR_PASSWD=${MAPR_PASSWD:-${INSTANCE_ID}}
MAPR_PASSWD=${MAPR_PASSWD:-MapRAZ}

# For CentOS and RedHat 6, the epel repository specification
# often references a mirrorlist of supporting hosts.  Unfortunately,
# this list often produces an error :
#	Error: Cannot retrieve repository metadata (repomd.xml) for 
#	repository: epel. Please verify its path and try again
#
# Resetting it to reference the baseurl directly seems to solve the problem
# 
function reset_epel() {
	epel_def=/etc/yum.repos.d/epel.repo
	[ ! -f $epel_def ] && return

		# TO BE DONE
		#	Be much smarter here ... make sure sed has desired effect
	sed -i 's/^mirrorlist=/#mirrorlist=/g' $epel_def
	sed -i 's/^#baseurl=/baseurl=/g'       $epel_def
	yum-config-manager -enable epel		    
}

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

		# For debugging, we might have a custom version of mapr-setup.sh
	if [ -f $BINDIR/mapr-setup.sh ] ; then
		cp $BINDIR/mapr-setup.sh /tmp
	fi

	reset_epel

		# We need to disable the requiretty constraint on sudo
	sed -i 's/ requiretty/ !requiretty/' /etc/sudoers

		# mapr-setup.sh uses different env variable for password.
	export MAPR_PASSWORD=$MAPR_PASSWD
	chmod a+x /tmp/mapr-setup.sh
	/tmp/mapr-setup.sh -y install
	if [ $? -ne 0 ] ; then
		echo "Failed to deploy MapR Installer with mapr-setup.sh" | tee -a $LOG
		exit 1
	fi

		# Make sure we have the "requests" package enabled 
		# (necessary for python script to drive the installer)
	/opt/mapr/installer/build/python/bin/pip install requests
	
		# And wait for the service to come to life (at least 2 minutes)
	SWAIT=120
	STIME=5
	/bin/false
	while [ $? -ne 0  -a  $SWAIT -gt 0 ] ; do
		sleep $STIME
		SWAIT=$[SWAIT - $STIME]
		curl -f -k -u mapr:$MAPR_PASSWORD https://localhost:9443 &> /dev/null
	done

# Once the installer has been successfully installed, you can 
# use the python script to talk with it
#
# ./deploy-mapr-cluster.py  
#	--hosts maprazure3node0,maprazure3node1 	# nodes from /etc/hosts
#	--ssh-user azadmin 
#	--ssh-password superStrong,123              # from template
#	--cluster itest 							# from template
#	--disks /dev/sdc,/dev/sdd,/dev/sde,/dev/sdf 	# auto-detect (should be in /tmp/MapR.disks)
#	--mapr-password MapRAZ						# must match MAPR_PASSWD above

}

set -x

main $@
exitCode=$?

set +x

exit $exitCode
