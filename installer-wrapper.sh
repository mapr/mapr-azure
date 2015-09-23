#!/bin/bash
#
# Wrapper script invocation of MapR installer service and auto-installation
# of MapR cluster.
#
# Assumptions: 
#	- script run as root
#	- all other scripts downloaded to same directory.
#
# WARNING: The file upload process from the Azure templates CLEARS the
#	execute bit on all files.   For that reason, we must to "sh <script>"
#	when chaining them together here.
#
# The key to the deployment is generating the hosts file to be used
# for cluster formation.  We assume that the hosts are all of the 
# form <base><n>, where <n> varies from 0 to cluster_size - 1.   
#
#
# USAGE :
#	$0 [ <basename> ] [ <size> ] [ <edition> ] [ <mapr_version> ]
#
#		<edition> defaults to M3
#		<mapr_version> defaults to 5.0.0
#
# EXAMPLE :
#	$0 testnode 4 M5
#
#		The effect would be a 4-node cluster with testnode0, testnode1, 
#		testnode2, and testnode3 ... licensed for M5
#
# TBD
#	Probably don't need the <basename> property, since we can extract it
#	from our own hostname ... but we'll keep it this way for now.
#	

THIS=`readlink -f $0`
BINDIR=`dirname $THIS`

# These admin user settings must match the template
#	(or be passed in)
SUDO_USER=azadmin
SUDO_PASSWD=MapRAzur3

HOSTNAME=`hostname`
CLUSTER_HOSTNAME_BASE="${HOSTNAME%node*}node"

sh $BINDIR/prepare-disks.sh

# These should be passed in via metadata
export MAPR_PASSWD=${5:-MapRAZ}
export AUTH_METHOD=${6:-Password}
export MAPR_VERSION=${4:-5.0.0} 
sh $BINDIR/prepare-node.sh

sh $BINDIR/gen-cluster-hosts.sh ${1:-$CLUSTER_HOSTNAME_BASE} ${2:-}

# used to lock the cluster later
sh $BINDIR/gen-create-lock.sh $SUDO_USER

# At this point, we only need to configure the installer service
# and launch the process on the one node.

# Simple test ... are we node 0 ?
[ "$HOSTNAME" != "${CLUSTER_HOSTNAME_BASE}0" ] && exit 0

# Let's distribute some ssh keys for our known accounts
#
sh $BINDIR/gendist-sshkey.sh $SUDO_USER $SUDO_PASSWD id_rsa
sh $BINDIR/gendist-sshkey.sh mapr $MAPR_PASSWD id_launch
ssh-keygen -t rsa -P '' -f ~/.ssh/id_rsa
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
cat ~mapr/.ssh/id_launch.pub >> ~/.ssh/authorized_keys



export MAPR_CLUSTER=AZtest
[ -f /tmp/mkclustername ] && MAPR_CLUSTER=`cat /tmp/mkclustername` 

chmod a+x $BINDIR/deploy-installer.sh
$BINDIR/deploy-installer.sh
[ $? -ne 0 ] && exit 1

# **** TBD *****
#	Confirm that all nodes are alive and have completed
#	the "prepare-node.sh" step.  Simplest check for that
#	is to look for prepare-mapr-node.log in /home/mapr
#		*** so long as mapr user is created by prepare-node ***
#
# For now, kludge this to just make sure the names resolve
CF_HOSTS_FILE=/tmp/maprhosts 
cp -p $CF_HOSTS_FILE ${CF_HOSTS_FILE}.orig
truncate --size 0 $CF_HOSTS_FILE
excluded_hosts=""
for h in `awk '{print $1}' ${CF_HOSTS_FILE}.orig` ; do
	hip=$(getent hosts $h | awk '{print $1}')

	if [ -n "$hip" ] ; then
		echo $h >> $CF_HOSTS_FILE
	else
		excluded_hosts="$excluded_hosts $h"
	fi
done

if [ -n "${excluded_hosts}" ] ; then
	echo ""
	echo "WARNING: DNS resolution failed for "
	echo "  $excluded_hosts"
	echo ""
	echo "Those nodes will be exempted from the deployment"
	echo ""
fi


sh $BINDIR/gen-lock-cluster.sh $SUDO_USER $AUTH_METHOD

	# Invoke installer
	#	By default, it will go to https://localhost:9443 ... which is fine
	#	ssh-user/ssh-password has to match what is in the template
chmod a+x $BINDIR/deploy-mapr-cluster.py
echo $BINDIR/deploy-mapr-cluster.py -y \
	--ssh-user $SUDO_USER \
	--ssh-password $SUDO_PASSWD \
	--cluster $MAPR_CLUSTER \
	--hosts-file /tmp/maprhosts \
	--disks-file /tmp/MapR.disks \
	--mapr-password $MAPR_PASSWD \
	--mapr-edition ${3:-M3} \
	--mapr-version ${4:-5.0.0} 

$BINDIR/deploy-mapr-cluster.py -y \
	--ssh-user $SUDO_USER \
	--ssh-password $SUDO_PASSWD \
	--cluster $MAPR_CLUSTER \
	--hosts-file /tmp/maprhosts \
	--disks-file /tmp/MapR.disks \
	--mapr-password $MAPR_PASSWD \
	--mapr-edition ${3:-M3} \
	--mapr-version ${MAPR_VERSION:-5.0.0} 

exit 0
