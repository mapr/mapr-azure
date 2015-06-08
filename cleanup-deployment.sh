#!/bin/bash
#
# Helper script to clean up after failed template deployment
#
# The resource names should align with those defined in 
# azuredeploy.json.

CLUSTER=${1:-tuck}
RESGROUP=${2:-mapr-dbt}

NUMNODES=3

# First, delete the nodes
for ((n=0; n<NUMNODES; n++))
do
	azure vm delete -q ${RESGROUP:-} ${CLUSTER}n${n}
done

# Now that the nodes are gone, all the other resources can be removed

# Storage
for ((n=0; n<NUMNODES; n++))
do
	azure storage account delete -q -g ${RESGROUP:-} ${CLUSTER}maprnode${n}
done

# Network
azure network public-ip delete -q -g ${RESGROUP:-} public.${CLUSTER}

for ((n=0; n<NUMNODES; n++))
do
	azure network nic delete -q -g ${RESGROUP:-} maprNIC${n}
#	azure network nic delete -q -g ${RESGROUP:-} ${CLUSTER}-NIC${n}
done

azure network vnet delete -q -g ${RESGROUP:-} virtual-network-${CLUSTER}
# azure network vnet delete -q -g ${RESGROUP:-} ${CLUSTER}-vnet

