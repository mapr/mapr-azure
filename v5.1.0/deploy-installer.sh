#!/bin/bash

THIS=`readlink -f $0`
BINDIR=`dirname $THIS`

LOG=/tmp/deploy-installer.log

INSTALLER_SETUP_URI=http://package.mapr.com/releases/installer/mapr-setup.sh
INSTALLER_HOME=/opt/mapr/installer

# The MapR Admin User defaults to "mapr" in the mapr-setup.sh script
# We'll set a different password (tied to the instance-id by default
murl_top=http://instance-data/latest/meta-data
INSTANCE_ID=$(curl -f $murl_top/instance-id)
MAPR_USER=${MAPR_USER:-mapr}
MAPR_GROUP=`id -gn ${MAPR_USER}`
MAPR_GROUP=${MAPR_GROUP:-mapr}
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

# Lots of AWS AMI's come with just the openjdk JRE installed;
# Try to make sure we have the complete JDK (when we can)
function completeJDK() {
	if which dpkg &> /dev/null ; then
		for jver in 7 8 ; do
			dpkg -l openjdk-${jver}-jre &> /dev/null
			[ $? -eq 0 ] && apt-get install -y openjdk-${jver}-jdk
		done
	elif which rpm &> /dev/null ; then
		for jver in 1.7.0 1.8.0 ; do
			rpm -qi java-${jver}-openjdk &> /dev/null
			[ $? -eq 0 ] && yum install -y java-${jver}-openjdk-devel
		done
	fi
}

function apply_nfs_mount_patch() {
	PLAYBOOKS_HOME=${INSTALLER_HOME}/ansible/playbooks

	cp $BINDIR/mount_local_fs.pl ${PLAYBOOKS_HOME}/files
	[ $? -ne 0 ] && return

	chmod a+r ${PLAYBOOKS_HOME}/files/mount_local_fs.pl
	chown --reference=${PLAYBOOKS_HOME} ${PLAYBOOKS_HOME}/files/mount_local_fs.pl

	cat << IP_EOF >> $PLAYBOOKS_HOME/install_packages.yml

  - copy: src=files/mount_local_fs.pl  dest="{{ mapr_home }}/bin/mount_local_fs.pl" backup=yes owner=root group=root mode=0755
    when: pkgs.find('mapr-nfs') != -1

IP_EOF
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
		cp /tmp/mapr-setup.sh /tmp/mapr-setup-released.sh
		cp $BINDIR/mapr-setup.sh /tmp
	fi

#	reset_epel
	completeJDK

		# We may need to disable the requiretty constraint on sudo
#	sed -i 's/ requiretty/ !requiretty/' /etc/sudoers

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
	${INSTALLER_HOME}/build/python/bin/pip install requests
	
		# And wait for the service to come to life (at least 2 minutes)
	SWAIT=120
	STIME=5
	/bin/false
	while [ $? -ne 0  -a  $SWAIT -gt 0 ] ; do
		sleep $STIME
		SWAIT=$[SWAIT - $STIME]
		curl -f -k -u mapr:$MAPR_PASSWORD https://localhost:9443 &> /dev/null
	done

		# If we need to debug the installer
#	sed -i "s/\"debug\": false/\"debug\": true/" ${INSTALLER_HOME}/data/properties.json
#	service mapr-installer reload

	return 0

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

main $@
exitCode=$?

# Long term, we only need to do this for 4.1.0 and 5.0.0
#	We can gate it by removing the fixed mount_local_fs.pl script
#	(see installer-wrapper.sh).
apply_nfs_mount_patch

exit $exitCode
