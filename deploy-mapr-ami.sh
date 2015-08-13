#! /bin/bash
#
#   $File: deploy-mapr-ami.sh $
#   $Date: Fri Sep 13 09:30:20 2013 -0700 $
#   $Author: dtucker $
#
# Script to be executed on top of a base MapR AMI within Azure.
# The AMI is pre-configured with with the following stable configuration:
#	Java has been installed 
#	the MapR software repositories are configured
#	the MAPR_USER exists (and thus ~${MAPR_USER} (MAPR_USER_DIR) is known) 
#	
# Expectations:
#	- Script run as root user (hence no need for permission checks)
#	- Root user's home directory is /root (a few places we use that)
#	- Basic distro differences (APT-GET vs YUM, etc) can be handled
#	    There are so few differences, it seemed better to manage one script.
#
# Pre-configured files
#	/home/mapr/sbin/deploy-mapr-ami.sh (this script)
#	/home/mapr/cfg/onenode.parm	(default 1-node cluster config)
#	/home/mapr/cfg/<N>node.lst  (config files for different cluster sizes)
#		NOTE : For Azure Template, we gather config files from github
#
# Input (TBD):
#	/tmp/mkclustername : Optional name for the cluster
#	/tmp/maprdstore : Optional specifications for MySQL data store (for Hive)
#	/tmp/maprhosts : Optional list of known hosts in cluster.
#		Lack of this file results in a single-node cluster being formed
#
#		FOR NOW: everything is derived from our hostname
#
# Tested with MapR 3.x and 4.x
#
#	NOTE: This script should be run ONCE AND ONLY ONCE.  We do a quick
#	check at the beginning to see if a hostid exists for the MapR
#	installation (that is our "lock-out").  
#

# Metadata for this installation ... pull out details that we'll need
# 
murl_top=http://instance-data/latest/meta-data
murl_attr="${murl_top}/attributes"

THIS_FQDN=$(curl -f $murl_top/hostname)
[ -z "${THIS_FQDN}" ] && THIS_FQDN=`hostname --fqdn`
THIS_HOST=${THIS_FQDN%%.*}
INSTANCE_ID=$(curl -f $murl_top/instance-id)
[ -z "${AMI_LAUNCH_INDEX}" ] && \
	AMI_LAUNCH_INDEX=$(curl -f $murl_top/ami-launch-index) 

# A comma separated list of packages (without the "mapr-" prefix)
# to be installed.   This script assumes that NONE of them have 
# been installed.
MAPR_PACKAGES=$(curl -f $murl_attr/maprpackages)
MAPR_PACKAGES=${MAPR_PACKAGES:-"core,fileserver"}
MAPR_DISKS_PREREQS=fileserver

# Definitions for our installation
#	Long term, we should handle reconfiguration of
#	these values at cluster launch ... but it's difficult
#	without a clean way of passing meta-data to the script
MAPR_HOME=/opt/mapr
MAPR_UID=${MAPR_UID:-2000}
MAPR_USER=${MAPR_USER:-mapr}
MAPR_GROUP=`id -gn ${MAPR_USER}`
MAPR_GROUP=${MAPR_GROUP:-mapr}
MAPR_PASSWD=${MAPR_PASSWD:-${INSTANCE_ID}}
MAPR_METRICS_DEFAULT=metrics

MAPR_BUILD=`cat $MAPR_HOME/MapRBuildVersion 2> /dev/null`
[ -n "${MAPR_BUILD}" ] && MAPR_VERSION=${MAPR_BUILD%.*.*}
MAPR_VERSION=${MAPR_VERSION:-4.1.0}

# Derived from above settings ... with reasonable defaults
MAPR_USER_DIR=`eval "echo ~${MAPR_USER}"`
MAPR_USER_DIR=${MAPR_USER_DIR:-/home/mapr}

# CloudFormation support
CF_HOSTS_FILE=/tmp/maprhosts			# must match file from CF Template
CF_LICENSE_TYPE=/tmp/maprlicensetype	# must match file from CF Template


LOG=/tmp/deploy-mapr.log

# Make sure sbin tools are in PATH
PATH=/sbin:/usr/sbin:/usr/bin:/bin:$PATH

# Helper utility to log the commands that are being run and
# save any errors to a log file
#	BE CAREFUL ... this function cannot handle command lines with
#	their own redirection.

c() {
  echo $* >> $LOG
  $* || {
	echo "============== $* failed at "`date` >> $LOG
    false
  }
  return $?
}

retry_wait_time=5

# ${1}: command to execute and retry
# ${2}: error message
# ${3}: max wait (default is 5 minutes)
function exec_and_retry()
{
	local timeLeft=${3:-300}
	eval ${1}
	rtn=$?
	while [ $rtn -ne 0  -a  ${timeLeft} -gt 0 ] ; do
		sleep $retry_wait_time
		timeLeft=$[timeLeft-$retry_wait_time]
		eval ${1}
		rtn=$?
	done
	
	if [ ${timeLeft} -le 0 ] ; then
		echo "ERROR: ${2}" | tee -a $LOG 
		echo "retried for ${3:-300} seconds" | tee -a $LOG
	fi

	return $rtn
}

# The first DHCP boot of the Amazon instances often sets
# the hostname WITHOUT updating the /etc/sysconfig file that
# will define that value on subsequent boots.   This may be
# a side effect of cloud-init  ... I don't know.   But we
# have to fix it for our VPC installations.
#
function verify_instance_hostname() {
	SYSCONFIG_NETWORK=/etc/sysconfig/network

	if [ -f $SYSCONFIG_NETWORK ] ; then
		eval "CFG_`grep ^HOSTNAME= /etc/sysconfig/network`"
		CUR_HOSTNAME=`hostname`

		if [ "$CFG_HOSTNAME" != "$CUR_HOSTNAME" ] ; then
			sed -i "s/^HOSTNAME=.*$/HOSTNAME=$CUR_HOSTNAME/" $SYSCONFIG_NETWORK
		fi
	fi
}


# Merge the known configurations with the CloudFormation 
# cluster assignments 
#
# Global Inputs
#	MAPR_USER_DIR
#	CF_HOSTS_FILE	# must exist
#
# Optional Inputs
#	CF_LICENSE_TYPE	# contains M3, M5, or M7
#
function generate_mapr_param_file() {
	echo Generating MapR installation parameter file >> $LOG

	local OFILE=$1

	NODE_PREFIX=MAPRNODE
	CFG_DIR=$MAPR_USER_DIR/cfg

	CLUSTER_SIZE=`grep -c -e " $NODE_PREFIX" $CF_HOSTS_FILE`
	[ -n "${CF_LICENSE_TYPE:-}"  -a  -f "${CF_LICENSE_TYPE}" ] && LIC_TYPE=`head -1 $CF_LICENSE_TYPE`

	[ -z "$LIC_TYPE" ] && LIC_TYPE=M3

		# Find the cluster file most closely matching our 
		# target size and license type
	fidx=${CLUSTER_SIZE:-1}
	if [ $fidx -ge 3  -a "${LIC_TYPE:-M3}" = "M3" ] ; then
		cfg_file=$CFG_DIR/M3.lst
	else
		while [ $fidx -gt 0 ] ; do
			cfg_file=$CFG_DIR/${fidx}node.lst
			[ -r $cfg_file ] && break
			fidx=$[fidx-1]
		done
	fi

		# SPECIAL CASE FOR AZURE
		#	Generate simple M3 cluster file
	if [ -z "${cfg_file:-}"  -o  ! -r "${cfg_file}" ] ; then
		echo "Error: No config found for $CLUSTER_SIZE nodes" | tee -a $LOG
		echo "Info: Defaulting to baseline M3 config" | tee -a $LOG

		cfg_file=/tmp/M3baseline.lst
		cat >> $cfg_file << EOF_m3config
# Simple M3 cluster ... 3 zk nodes + arbitrary number of data nodes
#
MAPRNODE0:zookeeper,cldb,fileserver,nodemanager,nfs,webserver,hbase
MAPRNODE1:zookeeper,fileserver,nodemanager,hbase
MAPRNODE2:zookeeper,resourcemanager,historyserver,fileserver,nodemanager,hbase
MAPRNODEn:fileserver,nodemanager,hbase
EOF_m3config
	fi

		# CF_HOSTS_FILE is of the form : [ HOST | IP ]  ${NODEPREFIX}<IDX>
		# Parse correctly with this logic
	MY_ID=`grep -w $THIS_HOST $CF_HOSTS_FILE | awk '{print $2}'`
	if [ -z "$MY_ID" ] ; then
		MY_IP=`hostname -I`
		MY_ID=`grep -w $MY_IP $CF_HOSTS_FILE | awk '{print $2}'`
	fi
	MY_IDX=${MY_ID#${NODE_PREFIX}}

		# If we don't find this host in CF_HOSTS_FILE,
		# assume we're just a "worker" node 
	if [ -z "${MY_ID:-}" ] ; then
		echo "WARNING: Neither host $THIS_HOST nor IP $MY_IP found in $CF_HOSTS_FILE" | tee -a $LOG
		MY_ID="${NODE_PREFIX}n"
	fi

		# Now the work starts
	cfg_entry=`grep ^$MY_ID $cfg_file`
	if [ -z "$cfg_entry" ] ; then
		cfg_entry=`grep "^${NODE_PREFIX}n" $cfg_file`
		if [ -z "$cfg_file" ] ; then
			echo "Error: No configuration found for $MY_ID in $cfg_file" | tee -a $LOG
			return 1
		fi
	fi

	packages=${cfg_entry#*:}
	[ -f /tmp/mkclustername ] && cluster=`cat /tmp/mkclustername`   
	cluster=${cluster:-awsmk}

	fidx=0
	while [ $fidx -lt $CLUSTER_SIZE ] ; do
		NODE_HOSTNAME=`grep " ${NODE_PREFIX}${fidx}" $CF_HOSTS_FILE | awk '{print $1}'`
		NODE_HOSTNAME=${NODE_HOSTNAME%%.*}
		cfg_entry=`grep "^${NODE_PREFIX}${fidx}" $cfg_file`
		NODE_PACKAGES=${cfg_entry#*:}

		fidx=$[fidx+1]
		[ -z "${NODE_PACKAGES}" ] && continue
	
		if [ $NODE_PACKAGES != "${NODE_PACKAGES%zookeeper*}" ] ; then 
			if [ -n "${zkhosts:-}" ] ; then zkhosts=$zkhosts','$NODE_HOSTNAME
			else zkhosts=$NODE_HOSTNAME
			fi
		fi

		if [ $NODE_PACKAGES != "${NODE_PACKAGES%cldb*}" ] ; then 
			if [ -n "${cldbhosts:-}" ] ; then cldbhosts=$cldbhosts','$NODE_HOSTNAME
			else cldbhosts=$NODE_HOSTNAME
			fi
		fi

			# These are kludges for 4.0.1
			# With 4.0.2 and beyond, this information is not needed
			# by configure.sh and thus we don't need to mess with this
		if [ $NODE_PACKAGES != "${NODE_PACKAGES%resourcemanager*}" ] ; then 
			if [ -n "${rmhosts:-}" ] ; then rmhosts=$rmhosts','$NODE_HOSTNAME
			else rmhosts=$NODE_HOSTNAME
			fi
		fi

		if [ $NODE_PACKAGES != "${NODE_PACKAGES%historyserver*}" ] ; then 
			hsnode=$NODE_HOSTNAME
		fi

	done

		# Last minute sanity checks before generating the param file
	if [ -z "$packages" ] ; then
		echo "Error: No MapR packages defined for installation" >> $LOG
		return 1
	fi
	if [ -z "$zkhosts" ] ; then
		echo "Error: No zknodes found in $cfg_file" >> $LOG
		return 1
	fi
	if [ -z "$cldbhosts" ] ; then
		echo "Error: No cldbnodes found in $cfg_file" >> $LOG
		return 1
	fi

	echo "MAPR_PACKAGES=$packages"             > $OFILE
	if [ -n "$maprCoreRepo:-}" ] ; then
		echo "MAPR_CORE_REPO=$maprCoreRepo"   >> $OFILE
	fi
	echo "cluster=$cluster"              >> $OFILE
	echo "zknodes=$zkhosts"              >> $OFILE
	echo "cldbnodes=$cldbhosts"          >> $OFILE
	echo "rmnodes=$rmhosts"              >> $OFILE
	echo "hsnode=$hsnode"                >> $OFILE

	if [ -n "${LIC_TYPE:-}" ] ; then
		lfile="$MAPR_USER_DIR/licenses/MaprMarketplace${LIC_TYPE}License.txt"
		if [ ! -r $lfile ] ; then
			curl -f http://maprtech-emr.s3.amazonaws.com/licenses/MaprMarketplaceM3License.txt -o /tmp/MaprMarketplace${LIC_TYPE}License.txt
			lfile="/tmp/MaprMarketplace${LIC_TYPE}License.txt"
		fi
		echo "MAPR_LICENSE_FILE=$lfile"  >> $OFILE
	fi
}

# Takes the packages defined by MAPR_PACKAGES and makes sure
# that those (and only those) pieces of MapR software are installed.
# The idea is that a single image with EXTRA packages could still 
# be used, and the extraneous packages would just be removed.
#	NOTE: We expect MAPR_PACKAGES to be short-hand (cldb, nfs, etc.)
#		instead of the full "mapr-cldb" name.  But the logic handles
#		all cases cleanly just in case.
# 	NOTE: We're careful not to remove mapr-core or -internal packages.
#
#	Input: MAPR_PACKAGES  (global)
#
install_mapr_packages() {
	echo Installing MapR software components >> $LOG

	installMetrics=0
	MAPR_TO_INSTALL=""
	for pkg in `echo ${MAPR_PACKAGES//,/ }`
	do
		[ "${pkg#mapr-}" = "metrics" ] && installMetrics=1
		MAPR_TO_INSTALL="$MAPR_TO_INSTALL mapr-${pkg#mapr-}"
	done

	if [ -n "${MAPR_TO_INSTALL}" ] ; then
		echo $MAPR_TO_INSTALL | grep -q mapr-client
		[ $? -ne 0 ] && CORE_FIRST=y
		if which dpkg &> /dev/null; then
			[ ${CORE_FIRST:-n} = 'y' ] && apt-get install -y --force-yes mapr-core
			apt-get install -y --force-yes $MAPR_TO_INSTALL
		elif which rpm &> /dev/null; then
			[ ${CORE_FIRST:-n} = 'y' ] && yum install -y mapr-core
			yum install -y $MAPR_TO_INSTALL
		fi
	fi

	echo MapR software installation complete >> $LOG

	return 0
}

function regenerate_mapr_hostid() {
	HOSTID=$($MAPR_HOME/server/mruuidgen)
	echo $HOSTID > $MAPR_HOME/hostid
	echo $HOSTID > $MAPR_HOME/conf/hostid.$$
	chmod 444 $MAPR_HOME/hostid

	HOSTNAME_FILE="$MAPR_HOME/hostname"
	if [ ! -f $HOSTNAME_FILE ]; then
		if [ -n "$THIS_FQDN" ] ; then
			echo "$THIS_FQDN" > $HOSTNAME_FILE
		elif [ -n "$THIS_HOST" ] ; then
			echo "$THIS_HOST" > $HOSTNAME_FILE
		else
			my_fqdn=`/bin/hostname --fqdn`
			[ -n "$my_fqdn" ] && echo "$my_fqdn" > $HOSTNAME_FILE
		fi
		
		if [ -f $HOSTNAME_FILE ] ; then
			chown $MAPR_USER:$MAPR_GROUP $HOSTNAME_FILE
		else
			echo "Cannot find valid hostname. Please check your DNS settings" >> $LOG
		fi
	fi

}

# Logic to search for unused disks and initialize the MAPR_DISKS
# parameter for use by the disksetup utility.
# As a first approximation, we simply look for any disks without
# a partition table and not mounted/used_for_swap/in_an_lvm and use them.
# This logic should be fine for any reasonable number of spindles.
#
find_mapr_disks() {
	echo Identifying local disks for MapR-FS >> $LOG

	disks=""
	for d in `fdisk -l 2>/dev/null | grep -e "^Disk .* bytes.*$" | awk '{print $2}' `
	do
		dev=${d%:}

		[ $dev != ${dev#/dev/mapper/} ] && continue		# skip udev devices

		mount | grep -q -w -e $dev -e ${dev}1 -e ${dev}2
		[ $? -eq 0 ] && continue

		swapon -s | grep -q -w $dev
		[ $? -eq 0 ] && continue

		if which pvdisplay &> /dev/null; then
			pvdisplay $dev &> /dev/null
			[ $? -eq 0 ] && continue
		fi

		disks="$disks $dev"
	done

		# Azure ALWAYS includes an ephemeral disk device, even if persistent
		# storage is provisioned.  The disk usually shows up as /dev/sdb.
		# That is VERY BAD for MapR, since restarting the node will
		# then always result in storage pool corruption.   For that reason, 
		# we'll eliminate /dev/sdb from our list in Azure (as determined 
		# by the presense of the Windows Azure Agent)
		#	TBD : be smarter about which device to remove
	if [ -f /etc/init.d/waagent ] ; then
		pdisks=$(echo $disks | sed -e 's|/dev/sdb||' -e 's/^[[:space:]]*//')
		[ -n "${pdisks:-}" ] && disks="$pdisks" 
	fi

	MAPR_DISKS="$disks"
	export MAPR_DISKS
}

# The Amazon images often mount one or more of the instance store
# disks ... just unmount it before looking for disks to be used by MapR.
#	BUT ONLY do that if we actually have the MAPR_DISKS_PREREQS packages !!!
provision_mapr_disks() {
	if [ -n "${MAPR_DISKS_PREREQS}" ] ; then
		pkgsToCheck=""
		for pkg in `echo ${MAPR_DISKS_PREREQS//,/ }`
		do
			pkgsToCheck="mapr-$pkg $pkgsToCheck"
		done

		abortProvisioning=0
		if which dpkg &> /dev/null; then
			dpkg --list $pkgsToCheck &> /dev/null
			[ $? -ne 0 ] && abortProvisioning=1
		elif which rpm &> /dev/null; then
			rpm -q $pkgsToCheck &> /dev/null
			[ $? -ne 0 ] && abortProvisioning=1
		fi
		if [ $abortProvisioning -ne 0 ] ; then
			echo "${MAPR_DISK_PREREQS} package(s) not found" >> $LOG
			echo "  local disks will not be configured for MapR" >> $LOG
			return 
		fi
	fi

	diskfile=/tmp/MapR.disks
	rm -f $diskfile
	find_mapr_disks
	if [ -n "$MAPR_DISKS" ] ; then
		for d in $MAPR_DISKS ; do echo $d ; done >> $diskfile
		$MAPR_HOME/server/disksetup -W 6 -F $diskfile

			# Archive the diskfile so we can reuse later
		cp $diskfile $MAPR_USER_DIR
	else
		echo "No unused disks found" >> $LOG
		if [ -n "$MAPR_DISKS_PREREQS" ] ; then
			for pkg in `echo ${MAPR_DISKS_PREREQS//,/ }`
			do
				echo $MAPR_PACKAGES | grep -q $pkg
				if [ $? -eq 0 ] ; then 
					echo "MapR package{s} $MAPR_DISKS_PREREQS installed" >> $LOG
					echo "Those packages require physical disks for MFS" >> $LOG
					echo "Exiting startup script" >> $LOG
					exit 1
				fi
			done
		fi
	fi

}


# Simple script to do any config file customization prior to 
# program launch
configure_mapr_services() {
	echo "Updating configuration for MapR services" >> $LOG

# Additional customizations ... to be customized based
# on instane type and other deployment details.   This is only
# necessary if the default configuration files from configure.sh
# are sub-optimal for Cloud deployments.  Some examples might be:
#	

	CLDB_CONF_FILE=${MAPR_HOME}/conf/cldb.conf
	MFS_CONF_FILE=${MAPR_HOME}/conf/mfs.conf
	WARDEN_CONF_FILE=${MAPR_HOME}/conf/warden.conf

# give MFS more memory -- only on slaves, not on masters
#sed -i 's/service.command.mfs.heapsize.percent=.*$/service.command.mfs.heapsize.percent=35/' $MFS_CONF_FILE

# give CLDB more threads 
# sed -i 's/cldb.numthreads=10/cldb.numthreads=40/' $CLDB_CONF_FILE

		# Fix for bug 11649 ; only seen with Debian/Ubuntu ... but
		# we'll do it for everyone
	if [ ${MAPR_VERSION%%.*} -ge 3 ] ; then
		if [ -f $MAPR_HOME/initscripts/mapr-cldb ] ; then
			sed -i 's/XX:ThreadStackSize=160/XX:ThreadStackSize=256/' \
				$MAPR_HOME/initscripts/mapr-cldb
		fi
	fi
}

# Simple script to add useful parameters to the 
# Hadoop *.xml configuration files.   This should be done
# as a separate Python or Perl script to better handle
# the xml format !!!
#
update_site_config() {
	echo "Updating site configuration files" >> $LOG

		# Default hadoop version changed with 4.x
	if [ ${MAPR_VERSION%%.*} -le 3 ] ; then
		HADOOP_HOME=${MAPR_HOME}/hadoop/hadoop-0.20.2
		HADOOP_CONF_DIR=${HADOOP_HOME}/conf
	else
		HADOOP_HOME="$(ls -d ${MAPR_HOME}/hadoop/hadoop-2*)"
		HADOOP_CONF_DIR=${HADOOP_HOME}/etc/hadoop
	fi

	MAPRED_CONF_FILE=${HADOOP_CONF_DIR}/mapred-site.xml
	CORE_CONF_FILE=${HADOOP_CONF_DIR}/core-site.xml
	YARN_CONF_FILE=${HADOOP_CONF_DIR}/yarn-site.xml

		# core-site changes need to include namespace mappings
    sed -i '/^<\/configuration>/d' ${CORE_CONF_FILE}

	echo "
<property>
  <name>hbase.table.namespace.mappings</name>
  <value>*:/tables</value>
</property>" | tee -a ${CORE_CONF_FILE}

	echo "" | tee -a ${CORE_CONF_FILE}
	echo '</configuration>' | tee -a ${CORE_CONF_FILE}

		# yarn-site changes needed for early 4.x releases, where 
		# yarn.resourcemanager.hostname is not properly recognized
		# by the web proxying services.   If we have only one
		# resource manager, force this fix to avoid the problem
	[ ! -f $YARN_CONF_FILE ] && return

	num_rms=`echo ${rmnodes//,/ } | wc -w`
	[ ${num_rms:-0} -ne 1 ] && return

    sed -i '/^<\/configuration>/d' ${YARN_CONF_FILE}

	echo "
<property>
<name>yarn.resourcemanager.hostname</name>
<value>$rmnodes</value>
</property>" | tee -a ${YARN_CONF_FILE}

	echo "" | tee -a ${YARN_CONF_FILE}
	echo '</configuration>' | tee -a ${YARN_CONF_FILE}
}

# Specific update for Hive configuration ... which depends
# on MySQL data store info being passed during instantiation
# (or a mysql data store on this node or the last known cluster node)
#
#	NOTE: $cluster and $zknodes are available from earlier sourcing 
#		of mapr.parm.  Other parameters found in maprdstore
#
update_hive_config() {
	echo "Updating hive-site configuration file" >> $LOG

	HIVE_SITE_XML=/opt/mapr/hive/hive-*/conf/hive-site.xml
	if [ ! -r $HIVE_SITE_XML ] ; then
		echo "  Config file ($HIVE_SITE_XML) not found; returning" >> $LOG
		return 1
	fi

	DB_PARAM_FILE=/tmp/maprdstore
	if [ -f $CF_HOSTS_FILE  -a ! -r $DB_PARAM_FILE ] ; then
		DB_HOST=`tail -1 $CF_HOSTS_FILE | awk '{print $1}'`
		DB_ID=`tail -1 $CF_HOSTS_FILE | awk '{print $2}'`
		[ "${DB_ID}" = "$MY_ID" ] && DB_HOST=localhost

		cat >> $DB_PARAM_FILE << EOF_mysqldb
username=$MAPR_USER
password=$DB_ID
dbhost=$DB_HOST
dbport=3306
EOF_mysqldb
	elif [ ! -r $DB_PARAM_FILE ] ; then
		test -f /etc/init.d/mysql -o -f /etc/init.d/mysqld
		[ $? -eq 0 ] && cat >> $DB_PARAM_FILE << EOF_localdb
username=$MAPR_USER
password=$MAPR_PASSWD
dbhost=localhost
dbport=3306
EOF_localdb
	fi

	if [ ! -r $DB_PARAM_FILE ] ; then
		echo "  Parameter file ($DB_PARAM_FILE) not found; returning" >> $LOG
		return 1
	fi

		# Look for parameters ... set default values to avoid terminal
		# corruption of the hive-site file.
	. $DB_PARAM_FILE
	dbhost=${dbhost:-DBHOST}
	dbport=${dbport:-3306}
	dbuser=${username:-DBUSER}
	dbpassword=${password:-DBPASSWORD}

	sed -e "s/zknodes/$zknodes/g" \
		-e "s/dbhost/$dbhost/" \
		-e "s/dbport/$dbport/" \
		-e "s/cluster/$cluster/" \
		-e "s/dbuser/$dbuser/" \
		-e "s/dbpassword/$dbpassword/" -i $HIVE_SITE_XML

		# Resolve the aux jars properly.
	HANDLER_JAR=$(ls $MAPR_HOME/hive/hive-*/lib/hive-hbase-handler-*.jar)
	HBASE_JAR=$(ls $MAPR_HOME/hbase/hbase-*/lib/hbase-client-*.jar)
	ZK_JAR=$(ls ${MAPR_HOME}/lib/zookeeper*.jar)

	if [ -n "$HANDLER_JAR"  -a  -n "$HBASE_JAR"  -a  -n "$ZK_JAR" ] ; then
		sed -e "s|HANDLER_JAR|$HANDLER_JAR|" \
		    -e "s|HBASE_JAR|$HBASE_JAR|" \
		    -e "s|ZK_JAR|$ZK_JAR|" -i $HIVE_SITE_XML
	fi

	[ $dbhost != "localhost" ] && return 0

		# If we're using the local database, start it up and
		# update the MapR user password (the database was initialized
		# in the ami).
	chkconfig mysqld on
	service mysqld start
	
	if [ $? -eq 0 ] ; then
		sleep 5					# let database come up cleanly
		mysql << mysqlEOF
grant all on hive_$cluster.* to '$dbuser'@'localhost' identified by '$dbpassword';
grant all on hive_$cluster.* to '$dbuser'@'%' identified by '$dbpassword';
quit
mysqlEOF
	fi

}

#
#  Wait until DNS can find all the zookeeper nodes
#	Should put a timeout ont this ... it's really not well designed
#
function resolve_zknodes() {
	echo "WAITING FOR DNS RESOLUTION of zookeeper nodes {$zknodes}" >> $LOG
	zkready=0
	while [ $zkready -eq 0 ]
	do
		zkready=1
		echo testing DNS resolution for zknodes
		for i in ${zknodes//,/ }
		do
			grep -q -w $i /etc/hosts		# check /etc/hosts first
			[ $? -eq 0 ] && continue
			[ -z "$(dig -t a +search +short $i)" ] && zkready=0
		done

		echo zkready is $zkready
		[ $zkready -eq 0 ] && sleep 5
	done
	echo "DNS has resolved all zknodes {$zknodes}" >> $LOG
	return 0
}


# MapR NFS services should be configured AFTER the cluster
# is running and the license is installed.
# 
# If the node is running NFS, then we default to a localhost
# mount; otherwise, we look for the spefication from our
# parameter file

MAPR_FSMOUNT=/mapr
MAPR_FSTAB=$MAPR_HOME/conf/mapr_fstab
SYSTEM_FSTAB=/etc/fstab

configure_mapr_nfs() {
	echo "Configuring MapR NFS service" >> $LOG

	if [ -f $MAPR_HOME/roles/nfs ] ; then
		MAPR_NFS_SERVER=localhost
		MAPR_NFS_OPTIONS="hard,intr,nolock"
	else
		MAPR_NFS_OPTIONS="hard,intr"
	fi

		# Bail out now if there's not NFS server (either local or remote)
	[ -z "${MAPR_NFS_SERVER:-}" ] && return 0

		# Performance tune for NFS client on fast networks
	SYSCTL_CONF=/etc/sysctl.conf
	echo "#"                >> $SYSCTL_CONF
	echo "# MapR NFS tunes" >> $SYSCTL_CONF
	echo "#"                >> $SYSCTL_CONF

	vmopts="vm.dirty_ratio=10"
	vmopts="$vmopts vm.dirty_background_ratio=4"
	for vmopt in $vmopts
	do
		echo $vmopt >> $SYSCTL_CONF
		sysctl -w $vmopt
	done

	sysctl -w sunrpc.tcp_slot_table_entries=128
	sysctl -w sunrpc.max_tcp_slot_table_entries=128
	if [ -d /etc/modprobe.d ] ; then
		SUNRPC_CONF=/etc/modprobe.d/sunrpc.conf
		grep -q tcp_slot_table_entries $SUNRPC_CONF  2> /dev/null
		if [ $? -ne 0 ] ; then
			echo "options sunrpc tcp_slot_table_entries=128" >> $SUNRPC_CONF
			echo "options sunrpc tcp_max_slot_table_entries=128" >> $SUNRPC_CONF
		fi
	fi

		# For RedHat distros, we need to start up NFS services
	if which rpm &> /dev/null; then
		/etc/init.d/rpcbind restart
		/etc/init.d/nfslock restart
	fi

	echo "Mounting ${MAPR_NFS_SERVER}:/mapr to $MAPR_FSMOUNT" >> $LOG
	mkdir $MAPR_FSMOUNT

	if [ $MAPR_NFS_SERVER = "localhost" ] ; then
		echo "${MAPR_NFS_SERVER}:/mapr	$MAPR_FSMOUNT	$MAPR_NFS_OPTIONS" >> $MAPR_FSTAB
		chmod a+r $MAPR_FSTAB

		maprcli node services -nfs restart -nodes `cat $MAPR_HOME/hostname`
	else
		echo "${MAPR_NFS_SERVER}:/mapr	$MAPR_FSMOUNT	nfs	$MAPR_NFS_OPTIONS	0	0" >> $SYSTEM_FSTAB
		mount $MAPR_FSMOUNT
	fi
}


function enable_mapr_services() 
{
	echo Enabling MapR services >> $LOG

	if which update-rc.d &> /dev/null; then
		[ -f $MAPR_HOME/conf/warden.conf ] && \
			c update-rc.d -f mapr-warden enable
		[ -f $MAPR_HOME/roles/zookeeper ] && \
			c update-rc.d -f mapr-zookeeper enable
	elif which chkconfig &> /dev/null; then
		[ -f $MAPR_HOME/conf/warden.conf ] && \
			c chkconfig mapr-warden on
		[ -f $MAPR_HOME/roles/zookeeper ] && \
			c chkconfig mapr-zookeeper on
	fi
}

function wait_for_user_ticket()
{
	grep -q "secure=true" $MAPR_HOME/conf/mapr-clusters.conf
	if [ $? -ne 0 ] ; then
		return
	fi

	USERTICKET=${MAPR_HOME}/conf/mapruserticket

	TICKET_WAIT=300

	SWAIT=$TICKET_WAIT
	STIME=3
	test -r $USERTICKET
	while [ $? -ne 0  -a  $SWAIT -gt 0 ] ; do
		sleep $STIME
		SWAIT=$[SWAIT - $STIME]
		test -r $USERTICKET
	done

	if [ -r $USERTICKET ] ; then
		MAPR_TICKETFILE_LOCATION=${USERTICKET}
		export MAPR_TICKETFILE_LOCATION
	fi
}

function start_mapr_services() 
{
	echo "Starting MapR services" >> $LOG

	if [ -f $MAPR_HOME/roles/zookeeper ] ; then
		c service mapr-zookeeper start
	fi
	if [ -f $MAPR_HOME/conf/warden.conf ] ; then
		c service mapr-warden start
	fi

		# This is as logical a place as any to wait for HDFS to
		# come on line.  If security is enabled, we need to wait
		# a few minutes for the user ticket to be generated FIRST
	grep -q "secure=true" $MAPR_HOME/conf/mapr-clusters.conf
	if [ $? -eq 0 ] ; then
		wait_for_user_ticket	
	fi

		# We REALLY need JAVA_HOME set here
	[ -f /etc/profile.d/javahome.sh ]  && . /etc/profile.d/javahome.sh

	HDFS_ONLINE=0
	HDFS_MAX_WAIT=600
	echo "Waiting for hadoop file system to come on line" | tee -a $LOG
	i=0
	while [ $i -lt $HDFS_MAX_WAIT ] 
	do
		hadoop fs -stat /  &> /dev/null
		if [ $? -eq 0 ] ; then
			curTime=`date`
			echo " ... success at $curTime !!!" | tee -a $LOG
			HDFS_ONLINE=1
			i=9999
			break
		else
			echo " ... timeout in $[HDFS_MAX_WAIT - $i] seconds ($THIS_HOST)"
		fi

		sleep 3
		i=$[i+3]
	done

	if [ ${HDFS_ONLINE} -eq 0 ] ; then
		echo "ERROR: MapR File Services did not come on-line" >> $LOG
		return 1
	fi

	return 0
}


# Archive the SSH keys into the cluster; we'll pull 
# them down later.  When all nodes are spinning up at the
# same time, this 'mostly' works to distribute keys ...
# since everyone waited for the CLDB to come on line.
#
# Root keys for nodes 0 and 1 are distributed; MapR keys
# for node 0 and all webserver nodes are distributed
#
function store_ssh_keys() 
{
	echo "Storing ssh keys in MapRFS (if necessary)" >> $LOG

	clusterKeyDir=/cluster-info/keys
	rootKeyFile=/root/.ssh/id_rsa.pub
	maprKeyFile=${MAPR_USER_DIR}/.ssh/id_rsa.pub

	if [ ${AMI_LAUNCH_INDEX:-2} -le 1  -a  -f ${rootKeyFile} ] ; then 
		echo "  Pushing $rootKeyFile to $clusterKeyDir" >> $LOG
		hadoop fs -put $rootKeyFile \
		  $clusterKeyDir/id_rsa_root.${AMI_LAUNCH_INDEX}
	fi
	if [ -f ${maprKeyFile} ] ; then
		if [ -${AMI_LAUNCH_INDEX:-1} -eq 0  -o  -f $MAPR_HOME/roles/webserver ]
		then
			echo "  Pushing $maprKeyFile to $clusterKeyDir" >> $LOG
			hadoop fs -put $maprKeyFile \
			  $clusterKeyDir/id_rsa_${MAPR_USER}.${AMI_LAUNCH_INDEX}
		fi 
	fi

		# if we didn't need to push any keys, lets take a quick sleep here
		# so that when we call retrieve_ssh_keys later we have a better
		# chance of actually seeing them
	if [ ${AMI_LAUNCH_INDEX:-0} -gt 1  -a  ! -f ${MAPR_HOME}/roles/webserver ]
	then 
		sleep 10
	fi
}


# Look to the cluster for shared ssh keys.  This function depends
# on the cluster being up and happy.  Don't worry about errors
# here, this is just a helper function
function retrieve_ssh_keys() 
{
	echo "Retrieving ssh keys for other cluster nodes" >> $LOG

	clusterKeyDir=/cluster-info/keys

	hadoop fs -stat ${clusterKeyDir}
	[ $? -ne 0 ] && return 0

	kdir=$clusterKeyDir
		
		# Copy root keys FIRST ... since the MapR user keys are 
		# more important (and we want to give more time)
	akFile=/root/.ssh/authorized_keys
	for kf in `hadoop fs -ls ${kdir} | grep ${kdir} | grep _root | awk '{print $NF}' | sed "s_${kdir}/__g"`
	do
		echo "  found $kf"
		if [ ! -f /root/.ssh/$kf ] ; then
			hadoop fs -get ${kdir}/${kf} /root/.ssh/$kf
			cat /root/.ssh/$kf >> ${akFile}
		fi
	done

	akFile=${MAPR_USER_DIR}/.ssh/authorized_keys
	for kf in `hadoop fs -ls ${kdir} | grep ${kdir} | grep _${MAPR_USER} | awk '{print $NF}' | sed "s_${kdir}/__g"`
	do
		echo "  found $kf"
		if [ ! -f ${MAPR_USER_DIR}/.ssh/$kf ] ; then
			hadoop fs -get ${kdir}/${kf} ${MAPR_USER_DIR}/.ssh/$kf
			cat ${MAPR_USER_DIR}/.ssh/$kf >> ${akFile}
			chown --reference=${MAPR_USER_DIR} \
				${MAPR_USER_DIR}/.ssh/$kf ${akFile}
		fi
	done
}

# For small clusters, it's nice to simplify the default replication
# factor and clean up the other volumes.
#	NOTE: There is still a race condidition during cluster startup that
#	often results in other system volumes being left with larger replication
#	values.   It's not worth fighting with that situation.
#
set_maprfs_replication_factor()
{
	[ ! -f $MAPR_HOME/roles/cldb ] && return 0
	[ ${MAPR_SANDBOX:-0} -eq 0 ] && return 0

	local replication_factor=${1:-1}

		# The creation of the system volumes may be going on as
		# this function is being executed.   Best to set the
		# default configuration values RIGHT AWAY .
	repargs="cldb.volumes.default.replication:${replication_factor}"
	repargs="${repargs},cldb.volumes.default.min.replication:${replication_factor}"
	repargs="{${repargs}}"
	maprcli config save -values $repargs
	if [ $? -ne 0 ] ; then
		echo "ERROR: unable to set default replication factors"
		return 1
	fi

	volumes=$(maprcli volume list -columns volumename -filter "[n==mapr\.*]" -noheader)
	for volume in ${volumes} ; do 
		maprcli volume modify -name ${volume} \
			-minreplication ${replication_factor} \
			-replication ${replication_factor}
		if [ $? -ne 0 ] ; then
			echo "Warning: unable to set the replication factor of ${volume} to ${replication_factor}"
		fi
	done

}


# Enable FullControl for MAPR_USER and install license if we've been
# given one.  When this function is run, we KNOW that the cluster
# is up and running (we have access to the distributed file system)
function finalize_mapr_cluster() 
{
	echo "Entering finalize_mapr_cluster" >> $LOG

	which maprcli  &> /dev/null
	if [ $? -ne 0 ] ; then
		echo "maprcli command not found" >> $LOG
		echo "This is typical on a client-only install" >> $LOG
		return 0
	fi
																
		# Run extra steps on CLDB nodes 
		#	(since they are needed only once per cluster)
	[ ! -f $MAPR_HOME/roles/cldb ] && return 0

		# Set lower replication factor if necessary
	set_maprfs_replication_factor

		# Allow root to manage cluster
	c maprcli acl edit -type cluster -user root:fc

	license_installed=0
	if [ -n "${MAPR_LICENSE_FILE:-}"  -a  -f "${MAPR_LICENSE_FILE}" ] ; then
		for lic in `maprcli license list | grep hash: | cut -d" " -f 2 | tr -d "\""`
		do
			grep -q $lic $MAPR_LICENSE_FILE
			[ $? -eq 0 ] && license_installed=1
		done

		if [ $license_installed -eq 0 ] ; then 
			echo "maprcli license add -license $MAPR_LICENSE_FILE -is_file true" >> $LOG
			maprcli license add -license $MAPR_LICENSE_FILE -is_file true >> $LOG
			[ $? -eq 0 ] && license_installed=1
		fi

		[ $license_installed -eq 1 ] && rm -f $MAPR_LICENSE_FILE
	else
		echo "No license provided ... please install one at your earliest convenience" >> $LOG
	fi

	MAPR_LICENSE_INSTALLED="$license_installed"
	export MAPR_LICENSE_INSTALLED

		# Last, but not least, create some useful volumes :
		#	/user/${MAPR_USER} 
		#	/tables				# for use ad default tables directory
	if [ ${AMI_LAUNCH_INDEX:-1} -eq 0 ] ; then 
		echo "Creating /user/${MAPR_USER} in configured cluster" >> $LOG

		su $MAPR_USER -c "maprcli volume create -name ${MAPR_USER}_home -path /user/$MAPR_USER -createparent true"
		[ $? -ne 0 ] && \
			echo "Error: unable to create /user directory for $MAPR_USER" >> $LOG

		su $MAPR_USER -c "maprcli volume create -name tables_vol -path /tables"
		if [ $? -eq 0 ] ; then
			hadoop fs -chmod 777 /tables			
		else
			echo "Error: unable to create /tables directory for $MAPR_USER" >> $LOG
		fi

		su $MAPR_USER -c "maprcli volume create -name shared_data_vol -path /data"
		if [ $? -eq 0 ] ; then
			hadoop fs -chmod 777 /data			
		else
			echo "Error: unable to create /data directory for $MAPR_USER" >> $LOG
		fi
	fi
}

#
# Disable starting of MAPR, and clean out the ID's that will be intialized
# with the full install. 
#	NOTE: the instantiation process from an image generated via
#	this script MUST recreate the hostid and hostname files
#
function deconfigure_mapr() 
{
	echo "Deconfiguring MapR software" >> $LOG

	c mv -f $MAPR_HOME/hostid    $MAPR_HOME/conf/hostid.image
	c mv -f $MAPR_HOME/hostname  $MAPR_HOME/conf/hostname.image

	if which dpkg &> /dev/null; then
		if [ -f $MAPR_HOME/conf/warden.conf ] ; then
			c update-rc.d -f mapr-warden remove
		fi
		echo $MAPR_PACKAGES | grep -q zookeeper
		if [ $? -eq 0 ] ; then
			c update-rc.d -f mapr-zookeeper remove
		fi
	elif which rpm &> /dev/null; then
		if [ -f $MAPR_HOME/conf/warden.conf ] ; then
			c chkconfig mapr-warden off
		fi
		echo $MAPR_PACKAGES | grep -q zookeeper
		if [ $? -eq 0 ] ; then
			c chkconfig mapr-zookeeper off
		fi
	fi
}

function update_mapr_user() {
	echo Configuring mapr user >> $LOG
	id $MAPR_USER &> /dev/null
	[ $? -ne 0 ] && return $? ;

		# Set the password as defined earlier (most often instance_id)
		# Remember to do it for mysql as well (later on)
	if [ -n "${MAPR_PASSWD}" ] ; then
		passwd $MAPR_USER << passwdEOF
$MAPR_PASSWD
$MAPR_PASSWD
passwdEOF

	fi

		# Enhance the login with rational stuff
    cat >> $MAPR_USER_DIR/.bashrc << EOF_bashrc

# PATH updates based on settings in MapR env file
MAPR_HOME=${MAPR_HOME:-/opt/mapr}
MAPR_ENV=\${MAPR_HOME}/conf/env.sh
[ -f \${MAPR_ENV} ] && . \${MAPR_ENV} 
[ -n "\${JAVA_HOME}:-" ] && PATH=\$PATH:\$JAVA_HOME/bin
[ -n "\${MAPR_HOME}:-" ] && PATH=\$PATH:\$MAPR_HOME/bin

set -o vi

EOF_bashrc

	return 0
}

function update_root_user() {
  echo "Updating root user" >> $LOG
  
    cat >> /root/.bashrc << EOF_bashrc

CDPATH=.:$HOME
export CDPATH

set -o vi

EOF_bashrc

	# Amazon shoves our key into the root users authorized_keys
	# file, but disables it explicitly.  This logic removes those
	# constraints (provided our key is an rsa key; you might want
	# to expand this to support dsa keys as well.
  sed -i -e "s/^.*ssh-rsa /ssh-rsa /g" /root/.ssh/authorized_keys

  ssh-keygen -q -t rsa -P "" -f /root/.ssh/id_rsa

  # We could take this opportunity to copy the public key of 
  # the mapr user into root's authorized key file ... but let's not for now
  return 0
}

function setup_mapr_repo_deb() {
    MAPR_REPO_FILE=/etc/apt/sources.list.d/mapr.list
    MAPR_CORE="http://package.mapr.com/releases/v${MAPR_VERSION}/ubuntu"
    MAPR_ECO="http://package.mapr.com/releases/ecosystem/ubuntu"

	if [ -n "${MAPR_CORE_REPO:-}" ] ; then
		curl -f $MAPR_CORE_REPO &> /dev/null
		if [ $? -eq 0 ] ; then 
			MAPR_CORE=$MAPR_CORE_REPO
			rm -f $MAPR_REPO_FILE
			MAPR_CORE_SPEC="$MAPR_CORE binary/"
		else
			MAPR_CORE_SPEC="$MAPR_CORE mapr optional"
		fi
	fi

	if [ -n "${MAPR_ECO_REPO:-}" ] ; then
		curl -f $MAPR_ECO_REPO &> /dev/null
		if [ $? -eq 0 ] ; then 
			MAPR_ECO=$MAPR_ECO_REPO
			rm -f $MAPR_REPO_FILE
		fi
	else
		major_ver=${MAPR_VERSION%%.*}
		if [ ${major_ver:-3} -gt 3 ] ; then
			ECO_SUFFIX="-${major_ver}.x"
			MAPR_ECO=${MAPR_ECO//ecosystem/ecosystem${ECO_SUFFIX}}
		fi
	fi

    if [ -f $MAPR_REPO_FILE ] ; then
  		sed -i "s|/releases/v.*/|/releases/v${MAPR_VERSION}/|" $MAPR_REPO_FILE
  		sed -i "s|/releases/ecosystem.*/|/releases/ecosystem${ECO_SUFFIX:-}/|" $MAPR_REPO_FILE
    	apt-get update
		return 
	fi

   	echo Setting up repos in $MAPR_REPO_FILE
   	cat > $MAPR_REPO_FILE << EOF_ubuntu
deb $MAPR_CORE_SPEC
deb $MAPR_ECO binary/
EOF_ubuntu

    apt-get update
}

function setup_mapr_repo_rpm() {
    MAPR_REPO_FILE=/etc/yum.repos.d/mapr.repo
    MAPR_CORE="http://package.mapr.com/releases/v${MAPR_VERSION}/redhat"
    MAPR_ECO="http://package.mapr.com/releases/ecosystem/redhat"

		# If there are overrides that point to something real, 
		# save them and remove the current REPO_FILE
	if [ -n "${MAPR_CORE_REPO:-}" ] ; then
		curl -f $MAPR_CORE_REPO &> /dev/null
		if [ $? -eq 0 ] ; then 
			MAPR_CORE=$MAPR_CORE_REPO
			rm -f $MAPR_REPO_FILE
		fi
	fi

	if [ -n "${MAPR_ECO_REPO:-}" ] ; then
		curl -f $MAPR_ECO_REPO &> /dev/null
		if [ $? -eq 0 ] ; then 
			MAPR_ECO=$MAPR_ECO_REPO
			rm -f $MAPR_REPO_FILE
		fi
	else
		major_ver=${MAPR_VERSION%%.*}
		if [ ${major_ver:-3} -gt 3 ] ; then
			ECO_SUFFIX="-${major_ver}.x"
			MAPR_ECO=${MAPR_ECO//ecosystem/ecosystem${ECO_SUFFIX}}
		fi
	fi

    if [ -f $MAPR_REPO_FILE ] ; then
  		sed -i "s|/releases/v.*/|/releases/v${MAPR_VERSION}/|" $MAPR_REPO_FILE
  		sed -i "s|/releases/ecosystem.*/|/releases/ecosystem${ECO_SUFFIX:-}/|" $MAPR_REPO_FILE
    	yum makecache fast
		return 
	fi

    echo Setting up repos in $MAPR_REPO_FILE
    cat > $MAPR_REPO_FILE << EOF_redhat
[MapR]
name=MapR Core Components
baseurl=$MAPR_CORE
${MAPR_CORE//package.mapr.com/archive.mapr.com}
enabled=1
gpgcheck=0
protected=1

[MapR_ecosystem]
name=MapR Ecosystem Components
baseurl=$MAPR_ECO
enabled=1
gpgcheck=0
protected=1
EOF_redhat

	yum makecache fast
}

function setup_mapr_repo() {
  echo "Initializing MapR Software repositories" >> $LOG

  if which dpkg &> /dev/null; then
    setup_mapr_repo_deb
  elif which rpm &> /dev/null; then
    setup_mapr_repo_rpm
  fi
}


function retrieve_mapr_security_credentials()
{
	echo "Retrieving MapR security credentials from $MAPR_SEC_MASTER" >> $LOG
	if [ -z "${MAPR_SSH_KEY}" ] ; then
		echo "  Error: no SSH_KEY specified; cannot copy credentials" >> $LOG
		return
	elif [ ! -r "${MAPR_USER_DIR}/.ssh/${MAPR_SSH_KEY}" ] ; then
		echo "  Error: SSH_KEY (${MAPR_USER_DIR}/.ssh/${MAPR_SSH_KEY}) not found; cannot copy credentials" >> $LOG
		return
	fi

		# The presence of maprserverticket and ssl_truststore on the master
		# is our confirmation that the credentials are completely generated 
		#	Yes, this is "boot and suspenders", but it is not clear
		#	that there is any consistency to the order that the
		#	keys are generated on the master node.

	exec_and_retry \
		"ssh -i $MAPR_USER_DIR/.ssh/${MAPR_SSH_KEY} -n -o StrictHostKeyChecking=no ${MAPR_USER}@${MAPR_SEC_MASTER} ls $MAPR_HOME/conf/maprserverticket" \
		"No master security ticket found"
	[ $? -ne 0 ] && return $?

	exec_and_retry \
		"ssh -i $MAPR_USER_DIR/.ssh/${MAPR_SSH_KEY} -n -o StrictHostKeyChecking=no ${MAPR_USER}@${MAPR_SEC_MASTER} ls $MAPR_HOME/conf/ssl_truststore" \
		"No ssl_truststore found"
	[ $? -ne 0 ] && return $?

		# Copying these over is a kludge, since we only have
		# clean ssh back to the Master node as the MapR user
		#
		# TO BE DONE : better error checking on these retrievals
	scp -i $MAPR_USER_DIR/.ssh/${MAPR_SSH_KEY} \
		${MAPR_USER}@${MAPR_SEC_MASTER}:$MAPR_HOME/conf/maprserverticket $HOME
	chown -R ${MAPR_USER}:${MAPR_GROUP} $HOME/maprserverticket
	mv $HOME/maprserverticket $MAPR_HOME/conf
	if [ $? -ne 0 ] ; then
		exitFailure "Could not save maprserverticket to ${MAPR_HOME}/conf"
		return 1
	fi

	scp -i $MAPR_USER_DIR/.ssh/${MAPR_SSH_KEY} -r \
		${MAPR_USER}@${MAPR_SEC_MASTER}:$MAPR_HOME/conf/ssl_keystore $HOME
	chown -R ${MAPR_USER}:${MAPR_GROUP} $HOME/ssl_keystore
	mv $HOME/ssl_keystore $MAPR_HOME/conf
	if [ $? -ne 0 ] ; then
		exitFailure "Could not save ssl_keystore to ${MAPR_HOME}/conf"
		return 1
	fi

	scp -i $MAPR_USER_DIR/.ssh/${MAPR_SSH_KEY} -r \
		${MAPR_USER}@${MAPR_SEC_MASTER}:$MAPR_HOME/conf/ssl_truststore $HOME
	chown -R ${MAPR_USER}:${MAPR_GROUP} $HOME/ssl_truststore
	${SUDO:-} mv $HOME/ssl_truststore $MAPR_HOME/conf
	if [ $? -ne 0 ] ; then
		exitFailure "Could not save ssl_keystore to ${MAPR_HOME}/conf"
		return 1
	fi

		# For both CLDB and ZK nodes, we need the cldb.key
	if [ -f $MAPR_HOME/roles/cldb  -o  -f $MAPR_HOME/roles/zookeeper ] ; then
		scp -i $MAPR_USER_DIR/.ssh/${MAPR_SSH_KEY} \
			${MAPR_USER}@${MAPR_SEC_MASTER}:$MAPR_HOME/conf/cldb.key $HOME
		chown -R ${MAPR_USER}:${MAPR_GROUP} $HOME/cldb.key
		mv $HOME/cldb.key $MAPR_HOME/conf
		if [ $? -ne 0 ] ; then
			echo "Could not save cldb.key to ${MAPR_HOME}/conf" | tee -a $LOG
			return 1
		fi
	fi

	return 0
}

function main() 
{
	echo "$0 script started at "`date`   | tee -a $LOG
	echo "    with args: $@"             | tee -a $LOG
	echo "    executed by: "`whoami`     | tee -a $LOG
	echo "    \$Revision: $"             | tee -a $LOG
	echo "    \$Date: $"                 | tee -a $LOG
	echo ""                              | tee -a $LOG


	if [ `id -u` -ne 0 ] ; then
		echo "	ERROR: script must be run as root" | tee -a $LOG
		exit 1
	fi

	verify_instance_hostname

		# Bail out here if we don't have a MAPR_USER configured
	[ `id -un $MAPR_USER` != "${MAPR_USER}" ] && return 1
	update_mapr_user

		# Bail out here if software already configured
	[ -f $MAPR_HOME/hostid ] && return 1
	
		# Look for the parameter file that will have the 
		# variables necessary to complete the installation
		# If we don't see a parameter file, look for a 
		#	1. The hosts file created by the Cloud Formation Template
		#	2. A "single-instance" file (default with the AMI)
	MAPR_PARAM_FILE=$MAPR_USER_DIR/mapr.parm

	if [ ! -f $MAPR_PARAM_FILE  -a  -f $CF_HOSTS_FILE ] ; then
		generate_mapr_param_file $MAPR_PARAM_FILE
	fi

	ONENODE_PARAM_FILE=$MAPR_USER_DIR/cfg/onenode.parm
	if [ ! -f $MAPR_PARAM_FILE  -a  -f $ONENODE_PARAM_FILE ] ; then
		sed "s/NODE0/$THIS_HOST/g" $ONENODE_PARAM_FILE > $MAPR_PARAM_FILE
		chown $MAPR_USER:$MAPR_GROUP ${MAPR_PARAM_FILE}
		MAPR_SANDBOX=1
	fi

	[ ! -f $MAPR_PARAM_FILE ] && return 1

		# And finish up the installation (if we have rational parameters)
		# Be careful ... this script has some defaults for MAPR_USER
		# and MAPR_HOME that we should probably check for overrides here.
	[ -r /etc/profile.d/javahome.sh ] &&  . /etc/profile.d/javahome.sh
	. $MAPR_PARAM_FILE
		
	if [ -z "${cluster}" -o  -z "${zknodes}"  -o  -z "${cldbnodes}" ] ; then
	    echo "Insufficient specification for MapR cluster ... terminating script" | tee -a $LOG
		exit 1
	fi

		# The parameters MAY have given us a new MAPR_VERSION 
		# setting (in the case where the meta-data was not available).
		# Update the repo specification appropriately.
		#	NOTE: Not necessary for AMI deployment
#	setup_mapr_repo

		# Since the AMI has mapr-core pre-installed, we'll need to 
		# regenerate the HOST_ID files AFTER the installation of our 
		# target packages (remember that we used hostid as a gate 
		# above to AVOID reconfiguring an already configured cluster)
	export MAPR_PACKAGES
	install_mapr_packages
	[ ! -f $MAPR_HOME/hostid ] && regenerate_mapr_hostid

		# Prepare to configure the node, supporting version-specific options
	major_ver=${MAPR_VERSION%%.*}
	ver=${MAPR_VERSION#*.}
	minor_ver=${ver%%.*}
	MVER=${major_ver}${minor_ver}	# Simpler representation ... 3.1.0 => 31

	VMARG="-noDB --isvm"		# Assume virtual env ... no MapR-DB optimization

	if [ $MVER -ge 31 ] ; then
		if [ "${MAPR_SECURITY:-}" = "master" ] ; then
			SECARG="-secure -genkeys"
		elif [ "${MAPR_SECURITY:-}" = "enabled" ] ; then
			SECARG="-secure"

				# If security is "enabled", but no SEC_MASTER, 
				# override setting here
			if [ -z "${MAPR_SEC_MASTER}" ] ; then
				SECARG="-unsecure"
			elif [ "${MAPR_SEC_MASTER%%.*}" = "$THIS_HOST" ] ; then
				SECARG="-secure -genkeys"
			else
				retrieve_mapr_security_credentials
				[ $? -ne 0 ] && SECARG="-unsecure"
					# TBD : should handle this error better
			fi
		else
			SECARG="-unsecure"
		fi
		AUTOSTARTARG="-f -no-autostart -on-prompt-cont y"
		verbose_flag="-v"
	fi

	if [ $MAPR_VERSION = "4.0.1"  ] ; then
		[ -n "$rmnodes" ] && YARNARG="-RM $rmnodes"
	fi
	[ -n "$hsnode" ] && YARNARG="${YARNARG:-} -HS $hsnode"


		# Waiting for the nodes at this point SHOULD be unnecessary,
		# since we had to have the node alive to re-spawn this part
		# of the script.  So we can just do the configuration
	c $MAPR_HOME/server/configure.sh \
		$verbose_flag \
		-N $cluster -C $cldbnodes -Z $zknodes ${YARNARG:-} \
	    -u $MAPR_USER -g $MAPR_GROUP \
		$AUTOSTARTARG $SECARG $VMARG

	configure_mapr_services
	update_site_config
	update_hive_config

	provision_mapr_disks

	enable_mapr_services

	resolve_zknodes
	if [ $? -eq 0 ] ; then
		start_mapr_services
		[ $? -ne 0 ] && return $?

		store_ssh_keys

		finalize_mapr_cluster

		configure_mapr_nfs

		retrieve_ssh_keys
	fi

	echo "$0 script completed at "`date` | tee -a $LOG
	echo IMAGE READY | tee -a $LOG
	return 0
}

main $@
exitCode=$?

# Save log to ~${MAPR_USER} ... since Ubuntu images erase /tmp
MAPR_USER_DIR=`eval "echo ~${MAPR_USER}"`
if [ -n "${MAPR_USER_DIR}"  -a  -d ${MAPR_USER_DIR} ] ; then
		cp $LOG $MAPR_USER_DIR
		chmod a-w ${MAPR_USER_DIR}/`basename $LOG`
		chown $MAPR_USER:$MAPR_GROUP ${MAPR_USER_DIR}/`basename $LOG`
fi

exit $exitCode
