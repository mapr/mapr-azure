#!/bin/bash
#
# Wrapper script invocation of MapR installer service and auto-installation
# of MapR cluster.
#
# Assumptions: all other scripts downloaded to same directory.
#
# WARNING: The file upload process from the Azure templates CLEARS the
#	execute bit on all files.   For that reason, we must to "sh <script>"
#	when chaining them together here.
#
# The key to the deployment is generating the hosts file to be used
# for cluster formation (since Azure does not yet support DNS lookup
# of hostnames assigned during resource creation.   We assume that
# the hosts are all of the form <base><n>, where <n> varies from 0 to
# cluster_size - 1.   The IP addresses are of the form <prefix><m>,
# were <m> is the index of the host plus the <first_ip> parameter.
#
#
# USAGE :
#	$0 [ <basename> ] [ <cluster_size> ] [ <cluster_edition> ] 
#
# EXAMPLE :
#	$0 testnode 4 M5
#
#		The effect would be a 4-node cluster with testnode0, testnode1, 
#		testnode2, and testnode3 ... licensed for M5
#
# CONSTRAINTS
#	The default IP addresses of the nodes are 10.0.0.x, with x starting at 10.
#	(See the defaults in gen-cluster-hosts.sh).
#
# TBD
#	Do a better job passing in the network addresses rather than forcing 
#   the defaults.
#	

THIS=`readlink -f $0`
BINDIR=`dirname $THIS`

HOSTNAME=`hostname`
CLUSTER_HOSTNAME_BASE="${HOSTNAME%node*}node"

sh $BINDIR/gen-cluster-hosts.sh ${1:-$CLUSTER_HOSTNAME_BASE} ${2:-3} 

sh $BINDIR/prepare-disks.sh

# At this point, we only need to configure the installer service
# and launch the process on the one node.

# Simple test ... are we node 0 ?
[ "$HOSTNAME" != "${CLUSTER_HOSTNAME_BASE}0" ] && exit 0

export MAPR_CLUSTER=AZtest
[ -f /tmp/mkclustername ] && MAPR_CLUSTER=`cat /tmp/mkclustername` 

export MAPR_PASSWD=MapRAZ
chmod a+x $BINDIR/deploy-installer.sh
$BINDIR/deploy-installer.sh

	# Invoke installer
	#	By default, it will go to https://localhost:9443 ... which is fine
	#	ssh-user/ssh-password has to match what is in the template
chmod a+x $BINDIR/deploy-mapr-cluster.py
$BINDIR/deploy-mapr-cluster.py -y \
	--ssh-user azadmin \
	--ssh-password MapRAzur3 \
	--cluster $MAPR_CLUSTER \
	--hosts-file /tmp/maprhosts \
	--disks-file /tmp/MapR.disks \
	--mapr-password $MAPR_PASSWD \
	--mapr-edition ${3:-M3} 

exit 0
