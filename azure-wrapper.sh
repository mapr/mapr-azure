#!/bin/bash
#
# Wrapper script around our deployment scripts.
#
# Assumptions: all other scripts downloaded to same directory.
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
#
# USAGE :
#	$0 [ <basename> ] [ <size> ] [ <edition> ] [ <mapr_version> ]
#	  [ <mapr_password> ] 
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

HOSTNAME=`hostname`
CLUSTER_HOSTNAME_BASE="${HOSTNAME%node*}node"

sh $BINDIR/prepare-disks.sh

# These should be passed in via metadata
export MAPR_PASSWD=${5:-MapRAZ}
export MAPR_VERSION=${4:-5.0.0} 
sh $BINDIR/prepare-node.sh

sh $BINDIR/gen-cluster-hosts.sh ${1:-$CLUSTER_HOSTNAME_BASE} ${2:-3} 

# deploy-mapr-ami.sh expects these files in /home/mapr; copy them there
echo "${3:-M3}" > /tmp/maprlicensetype
CFG_DIR=/home/mapr/cfg
mkdir -p $CFG_DIR
cp -p $BINDIR/*.lst $CFG_DIR
chown -R mapr:mapr $CFG_DIR

# and now deploy our software
#
chmod a+x $BINDIR/deploy-mapr-ami.sh
$BINDIR/deploy-mapr-ami.sh

if [ $? -eq 0 ] ; then
	sh $BINDIR/deploy-mapr-data-services.sh drill
fi

exit 0
