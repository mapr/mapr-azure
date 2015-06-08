#!/bin/bash
#
# Wrapper script around our deployment scripts.
#
# Assumptions: all other scripts downloaded to same directory.
#
# WARNING: The file upload process from the Azure templates CLEARS the
#	execute bit on all files.   For that reason, we must to "sh <script>"
#	when chaining them together here.

THIS=`readlink -f $0`
BINDIR=`dirname $THIS`

HOSTNAME=`hostname`
CLUSTER_HOSTNAME_BASE="${HOSTNAME%node*}node"

sh $BINDIR/gen-cluster-hosts.sh ${1:-$CLUSTER_HOSTNAME_BASE} ${2:-3} ${3:-} ${4:-}

sh $BINDIR/prepare-disks.sh

sh $BINDIR/prepare-node.sh

sh $BINDIR/deploy-mapr-ami.sh

