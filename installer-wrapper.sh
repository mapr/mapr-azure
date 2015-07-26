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
#	$0 [ <basename> ] [ <cluster_size> ] [ <IP_subnet_prefix> ] [ <first_ip> ]
#
# EXAMPLE :
#	$0 testnode 4 10.0.0. 10
#
#		The effect would be a 4-node cluster with testnode0, testnode1, 
#		testnode2, and testnode3 (at 10.10.10.[10-13]).
#	

THIS=`readlink -f $0`
BINDIR=`dirname $THIS`

HOSTNAME=`hostname`
CLUSTER_HOSTNAME_BASE="${HOSTNAME%node*}node"

sh $BINDIR/gen-cluster-hosts.sh ${1:-$CLUSTER_HOSTNAME_BASE} ${2:-3} ${3:-} ${4:-}

sh $BINDIR/prepare-disks.sh

#	sh $BINDIR/prepare-node.sh

#	sh $BINDIR/deploy-mapr-ami.sh

exit 0
