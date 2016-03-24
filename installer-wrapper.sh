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
#	$0 [ <basename> ] [ <size> ] [ <edition> ] [ <mapr_version> ] \
#	  [ <mapr_password> ] [ <auth_type> ] [ <admin_uer> ] [ <admin_password> ]
#
#		<edition> defaults to M3
#		<mapr_version> defaults to 5.0.0
#		<mapr_password> defaults to MapRAZ
#
#		<auth_type> : password or sshPublicKey (defaults to password)
#		<admin_user> defaults to azadmin
#		<admin_password> defaults to MapRAzur3
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
SUDO_USER=${7:-azadmin}
SUDO_PASSWD=${8:-MapRAzur3}

# We need to set the password, because it is *not* set in the case where
# we use PKI. We are going to later turn it off
echo -e "$SUDO_PASSWD\n$SUDO_PASSWD" | (passwd --stdin $SUDO_USER)

HOSTNAME=`hostname`
CLUSTER_HOSTNAME_BASE="${HOSTNAME%node*}node"

sh $BINDIR/prepare-disks.sh

# These should be passed in via metadata
export MAPR_PASSWD=${5:-MapRAZ}
export AUTH_METHOD=${6:-password}
export MAPR_VERSION=${4:-5.0.0} 
sh $BINDIR/prepare-node.sh

sh $BINDIR/gen-cluster-hosts.sh ${1:-$CLUSTER_HOSTNAME_BASE} ${2:-}

# For sshPublicKey deployments, we'll need to disable the
# PasswordAuthentication in sshd_config after the installer exits
sh $BINDIR/gen-create-lock.sh $SUDO_USER

# At this point, we only need to configure the installer service
# and launch the process on the one node ... the first one in the cluster

# Simple test ... are we node 0 ?
[ "$HOSTNAME" != "${CLUSTER_HOSTNAME_BASE}0" ] && exit 0

export MAPR_CLUSTER=AZtest
[ -f /tmp/mkclustername ] && MAPR_CLUSTER=`cat /tmp/mkclustername` 

chmod a+x $BINDIR/deploy-installer.sh
$BINDIR/deploy-installer.sh
[ $? -ne 0 ] && exit 1


# Make sure the hostnames in our cluster resolve.   There
# was a DNS issue in Azure at one point that caused problems here.
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

# On node0, let's get a real /etc/hosts.   This is a kludge
# until reverse address lookup works in Azure
for h in `cat $CF_HOSTS_FILE` ; do
	if [ $h = $HOSTNAME ] ; then
		echo `hostname -i`"        ${h}."`hostname -d` >> /etc/hosts
	else
		getent hosts $h >> /etc/hosts
	fi
done

# Let's distribute some ssh keys for our known accounts
#	NOTE: We should really confirm that all the nodes have
#	the mapr user configured BEFORE doing this ... but that's
#	a chicken-and-egg problem that we can't easily solve.
#
sh $BINDIR/gendist-sshkey.sh $SUDO_USER $SUDO_PASSWD id_rsa
sh $BINDIR/gendist-sshkey.sh mapr $MAPR_PASSWD id_launch
ssh-keygen -t rsa -P '' -f ~/.ssh/id_rsa
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
cat ~mapr/.ssh/id_launch.pub >> ~/.ssh/authorized_keys


# Now make sure that all the nodes have successfully 
# completed the "prepare" step.  The evidence of that is
# the existence of /home/mapr/prepare-mapr-node.log
#	NOTE: This depends on the successful execution of
#	gendist-sshkey for the mapr user above .
MAPR_USER=mapr
MAPR_USER_DIR=`eval "echo ~${MAPR_USER}"`
MY_SSH_OPTS="-i $MAPR_USER_DIR/.ssh/id_launch -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"
SSHPASS_OPTS="-o PasswordAuthentication=yes   -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

prepared_nodes=0
nnodes=`wc -l $CF_HOSTS_FILE | awk '{print $1}'`

PTIME=10
PWAIT=900                # wait no more than 15 minutes
while [ $prepared_nodes -ne $nnodes  -a  $PWAIT -gt 0 ] ; do
	echo "$prepared_nodes systems successfully prepared; waiting for $nnodes"

	sleep $PTIME
	PWAIT=$[PWAIT - $PTIME]
	prepared_nodes=0
	for h in `awk '{print $1}' ${CF_HOSTS_FILE}` ; do
		ssh $MY_SSH_OPTS $MAPR_USER@${h} \
			-n "ls ${MAPR_USER_DIR}/prepare-mapr-node.log" &> /dev/null
		sshRtn=$?
		if [ $sshRtn -eq 255 ] ; then
				# There is an race condition where the ssh key
				# does not get distributed by gendist-sshkey because
				# the mapr user is not provisioned on the some nodes 
				# by the time this node (node0) runs gendist-sshkey.
				# To deal with that, we'll try sshpass during the
				# if the initial ssh returns -1 (key-based access failing)
			SSHPASS=$MAPR_PASSWD /usr/bin/sshpass -e ssh $SSHPASS_OPTS $MAPR_USER@${h} \
				-n "ls ${MAPR_USER_DIR}/prepare-mapr-node.log" &> /dev/null
			[ $? -ne 0 ] && break
		elif [ $sshRtn -ne 0 ] ; then
			break
		fi
		prepared_nodes=$[prepared_nodes+1]
	done
done

if [ $PWAIT -eq 0 ] ; then
	echo "prepare-node.sh failed on some nodes; cannot proceed"
	exit 1
fi


	# Invoke installer
	#	By default, it will go to https://localhost:9443 ... which is fine
	#	ssh-user/ssh-password has to match what is in the template
	#
	# PYTRACE enables python tracing to stdout
	#	--trace [-t] traces everything
	#	--trackcalls posts cross-file function references

MIPKG=`rpm -qa --qf "%{NAME}-%{VERSION}\n" mapr-installer`
if [ "${MIPKG%.*}" = "mapr-installer-1.0" ] ; then
	PYTRACE="/opt/mapr/installer/build/python/bin/python -m trace -t "
fi

# Minor issue with hive on M5/M7 clusters ... disable for now
# if [ ${3:-M3} != "M3" ] ; then
#	ECO_HIVE='--eco-version hive=none'
# fi

[ "${MAPR_VERSION%%.*}" = "5" ] && \
	ECO_PIG="--eco-version pig=0.15"

# 23-Mar-2016: frequent deployment failures with Pig ... skip for now
ECO_PIG="--eco-version pig=none"

chmod a+x $BINDIR/deploy-mapr-cluster.py
echo $PYTRACE $BINDIR/deploy-mapr-cluster.py -y \
	--ssh-user $SUDO_USER \
	--ssh-password \$SUDO_PASSWD \
	--cluster $MAPR_CLUSTER \
	--hosts-file /tmp/maprhosts \
	--disks-file /tmp/MapR.disks ${ECO_HIVE:-} ${ECO_PIG:-} \
	--mapr-password \$MAPR_PASSWD \
	--mapr-edition ${3:-M3} \
	--mapr-version ${MAPR_VERSION:-5.0.0} 

MAX_TRIES=3
attempt=1
while [ $attempt -le $MAX_TRIES ] ; do
	$PYTRACE $BINDIR/deploy-mapr-cluster.py -y \
		--log-level INFO --log-file /opt/mapr/installer/logs/dmc.log \
		--ssh-user $SUDO_USER \
		--ssh-password $SUDO_PASSWD \
		--cluster $MAPR_CLUSTER \
		--hosts-file /tmp/maprhosts \
		--disks-file /tmp/MapR.disks ${ECO_HIVE:-} ${ECO_PIG:-} \
		--stage-user msazure \
		--stage-password MyCl0ud.ms \
		--mapr-password $MAPR_PASSWD \
		--mapr-edition ${3:-M3} \
		--mapr-version ${MAPR_VERSION:-5.0.0} 

	dmcRet=$?
	echo "Cluster Installation attempt $attempt returned status $dmcRet"

		# Exit on success or INSTALL failure; retry on INIT or CHECK failure
	if [ $dmcRet -eq 0  -o  $dmcRet -ge 3 ] ; then
		attempt=$[MAX_TRIES + 1]
	else
		[ $attempt -lt $MAX_TRIES ] && sleep 20
		attempt=$[attempt + 1]
	fi
done

# Post-install operations on successful deployment
if [ $dmcRet -eq 0  ] ; then
		# enable SUDO_USER to access the cluster
	[ ${SUDO_USER} != "root" ] && \
		su $MAPR_USER -c "maprcli acl edit -type cluster -user $SUDO_USER:login"

		# Restart NFS (in case we installed trial license)
	maprcli license apps -noheader | grep -q -w NFS
	[ $? -eq 0 ] && \
		maprcli maprcli node services -name nfs -action restart -filter '[csvc==nfs]'
fi

# For PublicKey-configured clusters, disable password authentication
#	NOTE: This means that the users will have to take the private
#	key from the Admin User to run the installer again.
[ $dmcRet -eq 0 ] && sh $BINDIR/gen-lock-cluster.sh $SUDO_USER $AUTH_METHOD

exit $dmcRet
