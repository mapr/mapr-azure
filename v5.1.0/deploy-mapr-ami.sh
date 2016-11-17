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
if [ -z "${AMI_LAUNCH_INDEX}" ] ; then
	AMI_LAUNCH_INDEX=$(curl -f $murl_top/ami-launch-index) 
	[ -z "${AMI_LAUNCH_INDEX}" ] && \
		AMI_LAUNCH_INDEX=${THIS_HOST#*node}

		# Special case for Sandbox launches (where the template
		# did not set hostname to "<cluster>node<n>"
	[ "${AMI_LAUNCH_INDEX}" = "${THIS_HOST}" ] && \
		AMI_LAUNCH_INDEX=0
fi

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
MAPR_PASSWD=${MAPR_PASSWD:-${INSTANCE_ID:-"MapR-${THIS_HOST}"}}
MAPR_METRICS_DEFAULT=metrics

MAPR_BUILD=`cat $MAPR_HOME/MapRBuildVersion 2> /dev/null`
[ -n "${MAPR_BUILD}" ] && MAPR_VERSION=${MAPR_BUILD%.*.*}
MAPR_VERSION=${MAPR_VERSION:-5.0.0}

# Derived from above settings ... with reasonable defaults
MAPR_USER_DIR=`eval "echo ~${MAPR_USER}"`
MAPR_USER_DIR=${MAPR_USER_DIR:-/home/mapr}

# CloudFormation support
CF_HOSTS_FILE=/tmp/maprhosts			# must match file from CF Template
CF_EDITION_SETTING=/tmp/maprlicensetype	# must match file from CF Template


LOG=/tmp/deploy-mapr-ami.log

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
		grep -q ^HOSTNAME= $SYSCONFIG_NETWORK
		if [ $? -eq 0 ] ; then
			eval "CFG_`grep ^HOSTNAME= $SYSCONFIG_NETWORK`"
			CUR_HOSTNAME=`hostname`

			if [ "$CFG_HOSTNAME" != "$CUR_HOSTNAME" ] ; then
				sed -i "s/^HOSTNAME=.*$/HOSTNAME=$CUR_HOSTNAME/" $SYSCONFIG_NETWORK
			fi
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
#	CF_EDITION_SETTING	# contains M3, M5, or M7
#
function generate_mapr_param_file() {
	echo Generating MapR installation parameter file | tee -a $LOG

	local OFILE=$1

	NODE_PREFIX=MAPRNODE
	CFG_DIR=$MAPR_USER_DIR/cfg

	CLUSTER_SIZE=`grep -c -e " $NODE_PREFIX" $CF_HOSTS_FILE`
	[ -n "${CF_EDITION_SETTING:-}"  -a  -f "${CF_EDITION_SETTING}" ] && LIC_TYPE=`head -1 $CF_EDITION_SETTING`

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
	cfg_entry=`grep -w ^$MY_ID $cfg_file`
	if [ -z "$cfg_entry" ] ; then
		cfg_entry=`grep "^${NODE_PREFIX}n" $cfg_file`
		if [ -z "$cfg_file" ] ; then
			echo "Error: No configuration found for $MY_ID in $cfg_file" | tee -a $LOG
			return 1
		fi
	fi

	packages=${cfg_entry#*:}
	[ -f /tmp/mkclustername ] && cluster=`cat /tmp/mkclustername`   
	cluster=${cluster:-azuremk}

	fidx=0
	while [ $fidx -lt $CLUSTER_SIZE ] ; do
		NODE_HOSTNAME=`grep " ${NODE_PREFIX}${fidx}$" $CF_HOSTS_FILE | awk '{print $1}'`
		NODE_HOSTNAME=${NODE_HOSTNAME%%.*}
		cfg_entry=`grep -w "^${NODE_PREFIX}${fidx}" $cfg_file`
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
		if [ -r $lfile ] ; then
			echo "MAPR_LICENSE_FILE=$lfile"  >> $OFILE
		fi
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
	echo Installing MapR software components | tee -a $LOG

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

	echo MapR software installation complete | tee -a $LOG

	return 0
}

# Retrieve the latest patch from the MapR repo and install it.
# This should be done AFTER the software is installed,
# but BEFORE the services are started.
#
install_mapr_patch()
{
	[ ! -f $MAPR_HOME/MapRBuildVersion ] && return

	echo Retrieving and installing latest MapR patch | tee -a $LOG

	MAPR_VERSION=`cat $MAPR_HOME/MapRBuildVersion | awk -F'.' '{print $1"."$2"."$3}'`

	REPO_URL=http://package.mapr.com
	PATCHES_TOP=$REPO_URL/patches/releases/v${MAPR_VERSION}
	if which dpkg &> /dev/null; then
		PATCHES_TOP=${PATCHES_TOP}/ubuntu
	elif which rpm &> /dev/null; then
		PATCHES_TOP=${PATCHES_TOP}/redhat
	fi

	pkg=$(curl -f ${PATCHES_TOP}/ | grep mapr-patch-${MAPR_VERSION} |  cut -d\" -f8)
	if [ -z "$pkg" ] ; then
		echo "  no patch found for $MAPR_VERSION; returning" | tee -a $LOG
		return
	fi

	curl -o /tmp/$pkg ${PATCHES_TOP}/$pkg
	if [ $? -ne 0 ] ; then
		echo "  failed to retrieve ${PATCHES_TOP}/$pkg; returning" | tee -a $LOG
		return
	fi

	yum install -y /tmp/$pkg
	if [ $? -ne 0 ] ; then
		echo MapR patch installation failed | tee -a $LOG
		return
	fi

	ORIG_CONFIG_SH="$(ls $MAPR_HOME/.patch/server/configure.sh.*)"
	if [ -n "$ORIG_CONFIG_SH" ] ; then
		$MAPR_HOME/server/configure.sh -R -noDB
	fi

	echo MapR patch installation complete | tee -a $LOG
}

# hostid is required to be unique across nodes in a cluster,
# so our AMI starts WITHOUT one.   Create it here.
#
# We've seen plenty of issues with /opt/mapr/hostname not
# being properly initialized by warden, so we'll seed
# here with a rational value.
#
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


# Simple function to do any config file customization prior to 
# program launch
configure_mapr_services() {
	echo "Updating configuration for MapR services" | tee -a $LOG

# Additional customizations ... to be customized based
# on instane type and other deployment details.   This is only
# necessary if the default configuration files from configure.sh
# are sub-optimal for Cloud deployments.  Some examples might be:
#	

	CLDB_CONF_FILE=${MAPR_HOME}/conf/cldb.conf
	MFS_CONF_FILE=${MAPR_HOME}/conf/mfs.conf
	WARDEN_CONF_FILE=${MAPR_HOME}/conf/warden.conf

# Configure log exceptions for Warden
	sed -e 's/^log.retention.exceptions=.*/log.retention.exceptions=mfs.log-\*,mfsinit.log,maprcli-\*.log,disksetup.\*.log,cldb.log,configure.log/' –i $WARDEN_CONF_FILE

# give MFS more memory -- only on slaves, not on masters
#sed -i 's/service.command.mfs.heapsize.percent=.*$/service.command.mfs.heapsize.percent=35/' $MFS_CONF_FILE

# give CLDB more threads 
# sed -i 's/cldb.numthreads=10/cldb.numthreads=40/' $CLDB_CONF_FILE

		# Change mapr-warden initscript to create use "hostname"
		# instead of "hostname --fqdn".  Since the micro-dns
		# in the cloud environment does the right thing with
		# name resolution, it's OK to use short hostnames
	sed -i 's/ --fqdn//' $MAPR_HOME/initscripts/mapr-warden

		# Fix for bug 11649 ; only seen with Debian/Ubuntu ... but
		# we'll do it for everyone
	if [ ${MAPR_VERSION%%.*} -ge 3 ] ; then
		if [ -f $MAPR_HOME/initscripts/mapr-cldb ] ; then
			sed -i 's/XX:ThreadStackSize=160/XX:ThreadStackSize=256/' \
				$MAPR_HOME/initscripts/mapr-cldb
		fi
	fi
}

# Hadoop 2.7 and beyond have simpler mechanisms for enabling
# cloud object stores.   We'll make sure the libraries are in
# the proper location here.
#	NOTE: For now, we'll make a copy (since there's lots of 
#	cross-contamination between these directories).
#
enable_object_stores() {
	HADOOP_HOME="$(ls -d ${MAPR_HOME}/hadoop/hadoop-2*)"
	[ -z "${HADOOP_HOME:-}" ] && return

	COMMON_LIB=$HADOOP_HOME/share/hadoop/common/lib
	TOOLS_LIB=$HADOOP_HOME/share/hadoop/tools/lib

		# WASB store
	for f in $TOOLS_LIB/*azure*.jar ; do
		jar=`basename $f`
		if [ ! -r $COMMON_LIB/$jar ] ; then
			cp -p $f $COMMON_LIB
		fi
	done

		# S3 store ... we need both the AWS SDK jars and some jackson
		# jars to support the s3a interfaces;
		# 	Be careful with jackson jars ... some MapR builds had 
		#	different versions in the two directories
	for f in $TOOLS_LIB/*aws*.jar ; do
		jar=`basename $f`
		if [ ! -r $COMMON_LIB/$jar ] ; then
			cp -p $f $COMMON_LIB
		fi
	done

	for f in $TOOLS_LIB/*jackson*.jar ; do
		jar=`basename $f`
		[ -r $COMMON_LIB/$jar ] && continue
		[ -r $COMMON_LIB/${jar%-*.jar}-[1-9]*.jar ] && continue

		cp -p $f $COMMON_LIB
	done
}

# Simple function to add useful parameters to the
# Hadoop *.xml configuration files.   This should be done
# as a separate Python or Perl script to better handle
# the xml format !!!
#
update_site_config() {
	echo "Updating site configuration files" | tee -a $LOG

		# Default hadoop version changed with 4.x
	if [ ${MAPR_VERSION%%.*} -le 3 ] ; then
		HADOOP_HOME=${MAPR_HOME}/hadoop/hadoop-0.20.2
		HADOOP_CONF_DIR=${HADOOP_HOME}/conf
	else
		HADOOP_HOME="$(ls -d ${MAPR_HOME}/hadoop/hadoop-2*)"
		HADOOP_CONF_DIR=${HADOOP_HOME}/etc/hadoop
	fi

	LOG4J_PROP_FILE=${HADOOP_CONF_DIR}/log4j.properties
	MAPRED_CONF_FILE=${HADOOP_CONF_DIR}/mapred-site.xml
	CORE_CONF_FILE=${HADOOP_CONF_DIR}/core-site.xml
	YARN_CONF_FILE=${HADOOP_CONF_DIR}/yarn-site.xml

	echo "
# Minimize extraneous INFO messages from WASB access
#
log4j.logger.org.apache.hadoop.metrics2.impl.MetricsSystemImpl=WARN
log4j.logger.org.apache.hadoop.metrics2.impl.MetricsConfig=WARN" | tee -a ${LOG4J_PROP_FILE}

		# core-site changes 
		#	- enable impersonation
		#	- include namespace mappings
    sed -i '/^<\/configuration>/d' ${CORE_CONF_FILE}

	echo "
<property>
  <name>hadoop.proxyuser.mapr.hosts</name>
  <value>*</value>
</property> 

<property>
  <name>hadoop.proxyuser.mapr.groups</name>
  <value>*</value>
</property> 

<property>
  <name>hbase.table.namespace.mappings</name>
  <value>*:/tables</value>
</property>" | tee -a ${CORE_CONF_FILE}

	echo "" | tee -a ${CORE_CONF_FILE}
	echo '</configuration>' | tee -a ${CORE_CONF_FILE}

	[ ! -f $MAPRED_CONF_FILE ] && return

		# mapred-site changes for smarter calculation of disk constraint
    sed -i '/^<\/configuration>/d' ${MAPRED_CONF_FILE}

		echo "
<property>
  <name>mapreduce.map.disk</name>
  <value>0.2</value>
</property>

<property>
  <name>mapreduce.reduce.disk</name>
  <value>0.5</value>
</property>
" | tee -a ${MAPRED_CONF_FILE}

	echo "" | tee -a ${MAPRED_CONF_FILE}
	echo '</configuration>' | tee -a ${MAPRED_CONF_FILE}

	[ ! -f $YARN_CONF_FILE ] && return

		# Enable YARN log aggregation
	echo "export MAPR_IMPERSONATION_ENABLED=true" >> ${HADOOP_CONF_DIR}/yarn-env.sh

    sed -i '/^<\/configuration>/d' ${YARN_CONF_FILE}

	echo "
<property>
<name>min.user.id</name>
<value>400</value>
</property>

<property>
<name>yarn.log-aggregation-enable</name>
<value>true</value>
</property>

<property>
<name>yarn.nodemanager.remote-app-log-dir</name>
<value>maprfs:///tmp/logs</value>
</property>

<property>
<name>yarn.nodemanager.log.retain</name>
<value>8640000</value>
<description>Log file retention (in seconds); set for 100 days</description>
</property>
" | tee -a ${YARN_CONF_FILE}

		# yarn-site changes needed for early 4.x releases, where 
		# yarn.resourcemanager.hostname is not properly recognized
		# by the web proxying services.   If we have only one
		# resource manager, force this fix to avoid the problem
	num_rms=`echo ${rmnodes//,/ } | wc -w`
	if [ ${MAPR_VERSION%%.*} -le 4  -a  ${num_rms:-0} -eq 1 ] ; then
		echo "
<property>
<name>yarn.resourcemanager.hostname</name>
<value>$rmnodes</value>
</property>" | tee -a ${YARN_CONF_FILE}

	fi

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
	echo "Updating hive-site configuration file" | tee -a $LOG

	HIVE_SITE_XML=/opt/mapr/hive/hive-*/conf/hive-site.xml
	if [ ! -r $HIVE_SITE_XML ] ; then
		echo "  Config file ($HIVE_SITE_XML) not found; returning" | tee -a $LOG
		return 1
	fi

		# Be sure to update the hive to the latest eco release
		# (maintaining the same Hive version)
	HIVE_PKG="mapr-$(cd /opt/mapr/hive; ls -d hive-*)*"
	yum update -y $HIVE_PKG

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
		if which systemctl &> /dev/null; then
			systemctl list-unit-files | grep -q -w -e mariadb -e mysql
			[ $? -eq 0 ] && DB_SERVICE=1
		else
			test -f /etc/init.d/mysql -o -f /etc/init.d/mysqld
			[ $? -eq 0 ] && DB_SERVICE=1
		fi

		[ ${DB_SERVICE:-0} -eq 1 ] && cat >> $DB_PARAM_FILE << EOF_localdb
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
		-e "s/cluster/${cluster/-/}/" \
		-e "s/dbuser/$dbuser/" \
		-e "s/dbpassword/$dbpassword/" -i $HIVE_SITE_XML

		# Resolve the aux jars properly.
	HADOOP_HOME="$(ls -d ${MAPR_HOME}/hadoop/hadoop-2*)"
	HANDLER_JAR=$(ls ${MAPR_HOME}/hive/hive-*/lib/hive-hbase-handler-*.jar)
	HBASE_JAR=$(ls ${MAPR_HOME}/hbase/hbase-*/lib/hbase-client-*.jar)
	ZK_JAR=$(ls ${HADOOP_HOME}/share/hadoop/common/lib/zookeeper*.jar)

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
	if [ $? -eq 0 ] ; then
		service mysqld start
	else
		chkconfig mariadb on
		[ $? -eq 0 ] && service mariadb start
	fi
	
	if [ $? -eq 0 ] ; then
		sleep 5					# let database come up cleanly
		mysql << mysqlEOF
grant all on hive_${cluster/-/}.* to '$dbuser'@'localhost' identified by '$dbpassword';
grant all on hive_${cluster/-/}.* to '$dbuser'@'%' identified by '$dbpassword';
quit
mysqlEOF
	fi

}

#
#  Wait until DNS can find all the zookeeper nodes
#	Should put a timeout ont this ... it's really not well designed
#
function resolve_zknodes() {
	echo "WAITING FOR DNS RESOLUTION of zookeeper nodes {$zknodes}" | tee -a $LOG
	zkready=0
	while [ $zkready -eq 0 ]
	do
		zkready=1
		echo testing DNS resolution for zknodes
		for z in ${zknodes//,/ }
		do
			if [ "$z" != "$THIS_HOST" -a "$z" != "$THIS_FQDN" ] ; then
				[ -z "$(dig -t a +search +short $z)" ] && zkready=0
			fi
		done

		echo zkready is $zkready
		[ $zkready -eq 0 ] && sleep 5
	done
	echo "DNS has resolved all zknodes {$zknodes}" | tee -a $LOG
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
	echo "Configuring MapR NFS service" | tee -a $LOG

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
		# RedHat 7 no longer has the nfslock service (nor is it necessary)
	if which rpm &> /dev/null; then
		service rpcbind restart
		[ -x /etc/init.d/nfslock ] && /etc/init.d/nfslock restart
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
	echo Enabling MapR services | tee -a $LOG

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
	echo "Starting MapR services" | tee -a $LOG

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
		echo "ERROR: MapR File Services did not come on-line" | tee -a $LOG
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

	hadoop fs -mkdir -p $clusterKeyDir 

	if [ ${AMI_LAUNCH_INDEX:-2} -le 1  -a  -f ${rootKeyFile} ] ; then 
		echo "  Pushing $rootKeyFile to $clusterKeyDir" >> $LOG
		hadoop fs -put $rootKeyFile \
		  $clusterKeyDir/id_rsa_root.${AMI_LAUNCH_INDEX}
	fi
	if [ -f ${maprKeyFile} ] ; then
		if [ ${AMI_LAUNCH_INDEX:-1} -eq 0  -o  -f $MAPR_HOME/roles/webserver ]
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
	echo "Entering finalize_mapr_cluster" | tee -a $LOG

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
	su $MAPR_USER -c "maprcli acl edit -type cluster -user root:fc"

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

		su $MAPR_USER -c "maprcli volume create -name hive_vol -path /user/hive"
		if [ $? -eq 0 ] ; then
			hadoop fs -chmod 777 /user/hive
			su $MAPR_USER -c "hadoop fs -mkdir /user/hive/warehouse"
			hadoop fs -chmod 777 /user/hive/warehouse
		else
			echo "Error: unable to create /user/hive directory for Hive Tables" >> $LOG
		fi

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

			# Enable "sysadmin" user to login and 
			# create a /user directory so they can run jobs
			# Enable a password so they can authenticate to secure clusters
			#	(default is INSTANCE_ID with "a" instead of "i" so
			#	that there's no overlap with mapr user)
		[ -d /home/ec2-user ] && SYSADMIN=ec2-user
		[ -d /home/ubuntu ] && SYSADMIN=ubuntu
		[ -f /etc/sudoers.d/waagent ] && SYSADMIN=`head /etc/sudoers.d/waagent | awk '{print $1}'`

		if [ -n "${SYSADMIN:-}" ] ; then
			su $MAPR_USER -c "maprcli acl edit -type cluster -user $SYSADMIN:login"
			su $MAPR_USER -c "maprcli volume create -name ${SYSADMIN}_home -path /user/${SYSADMIN}"
			su $MAPR_USER -c "hadoop fs -chown ${SYSADMIN}:${SYSADMIN} /user/${SYSADMIN}"

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
  echo "StrictHostKeyChecking no" >> /root/.ssh/config

  # We could take this opportunity to copy the public key of 
  # the mapr user into root's authorized key file ... but let's not for now
  return 0
}

function update_sudo_config() {
	echo "  updating sudo configuration" >> $LOG

	# allow sudo with ssh (we'll need to later)
  sed -i 's/^Defaults .*requiretty$/# Defaults requiretty/' /etc/sudoers

  echo "$MAPR_USER ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
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

# This update is needed in order to access AWS S3 buckets.
# Failure to do this results in a "peer not authenticated" error
# when trying to use hadoop commands against the S3 buckets.
# The timing needs to be such that the core credentials
# from the node where genkeys was run are already in place
# before this function gets called.
#
function update_ssl_truststore()
{
	[ -z "${MAPR_SECURITY:-}" ] && return

	echo "Updating MapR's SSL TrustStore with core java authorities" >> $LOG

	[ -z "$JAVA_HOME"  -a   -f /etc/profile.d/javahome.sh ]  && . /etc/profile.d/javahome.sh
	KEYTOOL=$JAVA_HOME/bin/keytool
	if [ ! -x $KEYTOOL ] ; then
		echo "  Error: cannot find $KEYTOOL" >> $LOG
		return
	fi

	JRE_TRUSTSTORE=$JAVA_HOME/jre/lib/security/cacerts
	JRE_STOREPASS=changeit

	MAPR_TRUSTSTORE=$MAPR_HOME/conf/ssl_truststore
	MAPR_STOREPASS=mapr123

	ENTRUST_LIST="entrustsslca entrust2048ca entrustevca"
	DIGICERT_LIST="digicertassuredidrootca digicerthighassuranceevrootca digicertglobalrootca"

	XFER_FILE=/tmp/xfer.cer
	for cert in $ENTRUST_LIST $DIGICERT_LIST ; do
		rm -f $XFER_FILE
		$KEYTOOL -exportcert -keystore $JRE_TRUSTSTORE -storepass $JRE_STOREPASS \
			-alias $cert -rfc -file $XFER_FILE

		[ $? -eq 0 ] && $KEYTOOL -importcert -keystore $MAPR_TRUSTSTORE -storepass $MAPR_STOREPASS \
			-alias $cert -file $XFER_FILE -trustcacerts -noprompt
	done
	rm -f $XVER_FILE

	echo "  update complete" >> $LOG
}

function retrieve_mapr_security_credentials()
{
	echo "Retrieving MapR security credentials from $MAPR_SEC_MASTER" >> $LOG
	if [ -z "${MAPR_SSH_KEY}" ] ; then
		echo "  Error: no SSH_KEY specified; cannot copy credentials" >> $LOG
		return 1
	elif [ ! -r "${MAPR_USER_DIR}/.ssh/${MAPR_SSH_KEY}" ] ; then
		echo "  Error: SSH_KEY (${MAPR_USER_DIR}/.ssh/${MAPR_SSH_KEY}) not found; cannot copy credentials" >> $LOG
		return 1
	fi

		# The presence of maprserverticket and ssl_truststore on the master
		# is our confirmation that the credentials are completely generated 
		#	Yes, this is "boot and suspenders", but it is not clear
		#	that there is any consistency to the order that the
		#	keys are generated on the master node.

	exec_and_retry \
		"ssh -i $MAPR_USER_DIR/.ssh/${MAPR_SSH_KEY} -n -o StrictHostKeyChecking=no ${MAPR_USER}@${MAPR_SEC_MASTER} ls $MAPR_HOME/conf/maprserverticket" \
		"No master security ticket found"
	[ $? -ne 0 ] && return 1

	exec_and_retry \
		"ssh -i $MAPR_USER_DIR/.ssh/${MAPR_SSH_KEY} -n -o StrictHostKeyChecking=no ${MAPR_USER}@${MAPR_SEC_MASTER} ls $MAPR_HOME/conf/ssl_truststore" \
		"No ssl_truststore found"
	[ $? -ne 0 ] && return 1

		# Copying these over is a kludge, since we only have
		# clean ssh back to the Master node as the MapR user
		#
		# TO BE DONE : better error checking on these retrievals
	scp -i $MAPR_USER_DIR/.ssh/${MAPR_SSH_KEY} \
		${MAPR_USER}@${MAPR_SEC_MASTER}:$MAPR_HOME/conf/maprserverticket $MAPR_HOME
	chown -R ${MAPR_USER}:${MAPR_GROUP} $MAPR_HOME/maprserverticket
	mv $MAPR_HOME/maprserverticket $MAPR_HOME/conf
	if [ $? -ne 0 ] ; then
		exitFailure "Could not save maprserverticket to ${MAPR_HOME}/conf"
		return 1
	fi

	scp -i $MAPR_USER_DIR/.ssh/${MAPR_SSH_KEY} -r \
		${MAPR_USER}@${MAPR_SEC_MASTER}:$MAPR_HOME/conf/ssl_keystore $MAPR_HOME
	chown -R ${MAPR_USER}:${MAPR_GROUP} $MAPR_HOME/ssl_keystore
	mv $MAPR_HOME/ssl_keystore $MAPR_HOME/conf
	if [ $? -ne 0 ] ; then
		exitFailure "Could not save ssl_keystore to ${MAPR_HOME}/conf"
		return 1
	fi

	scp -i $MAPR_USER_DIR/.ssh/${MAPR_SSH_KEY} -r \
		${MAPR_USER}@${MAPR_SEC_MASTER}:$MAPR_HOME/conf/ssl_truststore $MAPR_HOME
	chown -R ${MAPR_USER}:${MAPR_GROUP} $MAPR_HOME/ssl_truststore
	${SUDO:-} mv $MAPR_HOME/ssl_truststore $MAPR_HOME/conf
	if [ $? -ne 0 ] ; then
		exitFailure "Could not save ssl_keystore to ${MAPR_HOME}/conf"
		return 1
	fi

		# For both CLDB and ZK nodes, we need the cldb.key
	if [ -f $MAPR_HOME/roles/cldb  -o  -f $MAPR_HOME/roles/zookeeper ] ; then
		scp -i $MAPR_USER_DIR/.ssh/${MAPR_SSH_KEY} \
			${MAPR_USER}@${MAPR_SEC_MASTER}:$MAPR_HOME/conf/cldb.key $MAPR_HOME
		chown -R ${MAPR_USER}:${MAPR_GROUP} $MAPR_HOME/cldb.key
		mv $MAPR_HOME/cldb.key $MAPR_HOME/conf
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
	echo ""                              | tee -a $LOG
	echo "LAUNCH_INDEX ${AMI_LAUNCH_INDEX:-unknown}"  | tee -a $LOG
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
		nhosts=$(wc -l $CF_HOSTS_FILE | awk '{print $1}')
		[ ${nhosts:-0} -eq 1 ] && MAPR_SANDBOX=1
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

		# Best to grab the latest patch HERE, after running
		# configure.sh but before disksetup (and our customization
		# of the config files).  install_mapr_patch
		# will re-run configure.sh if it has been updated.
		# configure.sh in case it has been updated.
	[ -f /tmp/maprversion ] && cft_maprversion=`cat /tmp/maprversion`
	[ "${cft_maprversion#*-}" = "EBF" ] && install_mapr_patch

		# Bug 21897 : M3 and M7 clusters reserver 4 cpus for MFS.
		# Never useful in Virtual environments
		#	(where we don't have that many cores)
	ISC_FILE=$MAPR_HOME/server/initscripts-common.sh
	sed -i "s/mfscpus=2/mfscpus=1/g" $ISC_FILE
	sed -i "s/mfscpus=4/mfscpus=1/g" $ISC_FILE

	[ "${SECARG%% *}" = "-secure" ] && update_ssl_truststore
	configure_mapr_services
	enable_object_stores
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

