#!/bin/bash

LOG=/tmp/gen-cluster-hosts.log

#
# VERY SIMPLE Script to generate the list of hosts within this cluster.
#
# Original design:
#	add entries to /etc/hosts for nodes not found with getent(1M)
#
# Current design
#	print out errors when node resolution fails
#
# Requirements:
#	In the case of adding entries to /etc/hosts, the IP_PREFIX and
#	FIRST_IP arguments must match the deployment template
#
# NOTE: the CF_HOSTS_FILE is used by multiple other scripts as
# part of the complete cluster deployment
#

echo "$0 script started at "`date`   | tee -a $LOG
echo "    with args: $@"             | tee -a $LOG
echo "    executed by: "`whoami`     | tee -a $LOG
echo ""                              | tee -a $LOG


CLUSTER_HOSTNAME_BASE=${1:-}
CLUSTER_SIZE=${2:-}
CLUSTER_IP_PREFIX=${3:-"10.0.0."}
CLUSTER_IP_FIRST=${4:-10}

# Don't do anything if bogus parameters are passed in 
[ -z "${CLUSTER_HOSTNAME_BASE}"  -o  -z "${CLUSTER_SIZE}" ] && exit 0

CF_HOSTS_FILE=/tmp/maprhosts    # Helper file
truncate --size 0 $CF_HOSTS_FILE

echo "" | tee -a /etc/hosts
for ((h=0; h<CLUSTER_SIZE; h++))
do
	hname=${CLUSTER_HOSTNAME_BASE}$h
#	hip=$(dig -t a +search +short $hname)
	hip=$(getent hosts $hname | awk '{print $1}')

	if [ -z "$hip" ] ; then
#		hip=${CLUSTER_IP_PREFIX}$[h+$CLUSTER_IP_FIRST]
#		echo "$hip $hname" | tee -a /etc/hosts
		echo "getent(1M) could not resolve $hname" | tee -a $LOG
	fi

	echo "$hname MAPRNODE${h}" >> $CF_HOSTS_FILE

done

# Last kludge ... assume these CLUSTER_HOSTNAME_BASE is of the
# form <cluster>node ... and save off the cluster name
echo ${CLUSTER_HOSTNAME_BASE%node} > /tmp/mkclustername

# Really last kludge ... put hostname list into /etc/clustershell/groups
# if it exists
if [ -f /etc/clustershell/groups ] ; then
	nodes=`echo $(awk '{print $1}' $CF_HOSTS_FILE)`
	if [ -n "$nodes" ] ; then
		echo "all: ${nodes// /,}" > /etc/clustershell/groups
	fi
fi

echo "$0 script completed at "`date` | tee -a $LOG
