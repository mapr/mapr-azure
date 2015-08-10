#!/bin/bash

LOG=/tmp/gen-cluster-hosts.log

# VERY SIMPLE Script to generate the /etc/hosts file for our cluster
#	IF AND ONLY IF the hostnames don't resolve via dig
#
# Expect the template to pass in the hostname base and cluster size.
# The IP_PREFIX and FIRST_IP should match the template ... or pass them in
# as arguments.
#
# NOTE: the CH_HOSTS_FILE is used by multiple other scripts as
# part of the complete cluster deployment
#


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
	hip=$(dig -t a +search +short $hname)

	if [ -z "$hip" ] ; then
		hip=${CLUSTER_IP_PREFIX}$[h+$CLUSTER_IP_FIRST]
		echo "$hip $hname" | tee -a /etc/hosts
	fi

	echo "$hname MAPRNODE${h}" >> $CF_HOSTS_FILE

done

# Last kludge ... assume these CLUSTER_HOSTNAME_BASE is of the
# form <cluster>node ... and save off the cluster name
echo ${CLUSTER_HOSTNAME_BASE%node} > /tmp/mkclustername

