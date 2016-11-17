#! /bin/bash
#
#   $File: deploy-mapr-hiveserer.sh $
#   $Date: Fri Aug 28 17:49:05 PDT 2015 $
#   $Author: dtucker $
#	$Revision: 1.1 $
#
# Deploy data services on top of a __running__ MapR cluster.
#	repeat ... a __running__ MapR cluster
#
# This script should only be run AFTER the successful completion of the 
# deploy-mapr-ami.sh script in a CloudFormation operation.
#
#
# usage:
#	deploy-mapr-data-services.sh <service1> [ <service2> <service3> ]
#
# Supported services
#	hiveserver : deploys hivemetastore and hivserver2.  Assumes hive-site.xml
#		has proper configuration (including existing Metastore DB)
#		Should be done ONLY on 1-node
#
#	drill : deploys mapr-drill package.  Assumes cluster ZK will be used
#		NOTE: will configure HIVE plugin if metastore service found ... so
#		make sure that "hiveserver" is specified BEFORE drill
#			We enable centralized storage of query profiles via blobroot
#
#	spark : deploys mapr-spark package alongside mapr-resourcemanager
#		NOTE: spark-jobhistory installed at the same place as
#		mapr-historyserver
#
# TBD services
#
#	hue : 
#

LOG=/tmp/deploy-mapr-data-services.log

# Definitions for our installation
#	Long term, we should handle reconfiguration of
#	these values at cluster launch ... but it's difficult
#	without a clean way of passing meta-data to the script
MAPR_HOME=/opt/mapr
MAPR_USER=${MAPR_USER:-mapr}
MAPR_USER_DIR=`eval "echo ~${MAPR_USER}"`

# Ignore earlier MapR releases for now
HADOOP_HOME="$(ls -d ${MAPR_HOME}/hadoop/hadoop-2*)"
HADOOP_CONF_DIR=${HADOOP_HOME}/etc/hadoop

# For secure clusters, leverage the admin user's ticket for our
# maprcli operations
grep -q -e "secure=true" /opt/mapr/conf/mapr-clusters.conf
[ $? -eq 0 ] && export MAPR_TICKETFILE_LOCATION=/opt/mapr/conf/mapruserticket


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

# Wait for hive services to come on line
#	Warden reports "running" well before the service is really
#	running.   We'll wait for the listen port port to be active 
#	as well.
function wait_for_hive_service()
{
	svc=$1
	MAX_WAIT_TIME=${2:-300}

	SVC_ONLINE=0
	echo "Waiting for Hive service $svc to come on line" | tee -a $LOG
	i=0
	while [ $i -lt $MAX_WAIT_TIME ] 
	do
		hadoop fs -stat /  &> /dev/null
		svc_running=`maprcli node list -filter "[service==$svc]" -columns name -noheader | wc -l`
		if [ ${svc_running:-0} -ge 1 ] ; then
			curTime=`date`
			echo " ... success at $curTime !!!" | tee -a $LOG
			SVC_ONLINE=1
			[ $i -gt 0 ] && SVC_ONLINE=$i
			i=9999
			break
		else
			echo " ... timeout in $[MAX_WAIT_TIME - $i] seconds"
		fi

		sleep 3
		i=$[i+3]
	done

	[ $SVC_ONLINE -eq 0 ] && return 1
	echo "Hive service $svc started after $SVC_ONLINE seconds" | tee -a $LOG

		# Keep max_wait time cumulative
	i=$SVC_ONLINE
	SVC_ONLINE=0

	if [ $svc = "hivemeta" ] ; then
		svc_port=9083
	elif [ $svc = "hs2" ] ; then
		svc_port=10000
	fi

	[ -z "$svc_port" ] && return 0
	echo "Confirm that service is listening on port $svc_port" | tee -a $LOG

	while [ $i -lt $MAX_WAIT_TIME ]
	do
		lsof -i:$svc_port &> /dev/null
		if [ $? -eq 0 ] ; then
			curTime=`date`
			echo " ... success at $curTime !!!" | tee -a $LOG
			SVC_ONLINE=1
			[ $i -gt 0 ] && SVC_ONLINE=$i
			i=9999
			break
		else
			echo " ... timeout in $[MAX_WAIT_TIME - $i] seconds"
		fi

		sleep 3
		i=$[i+3]
	done

	if [ $SVC_ONLINE -ne 0 ] ; then
		echo "Hive service $svc listening on port $svc_port after $SVC_ONLINE seconds" | tee -a $LOG
		return 0
	else
		return 1
	fi

}

# All we need to do is install the services.
# The earlier script (deploy-mapr-ami.sh) has done all the heavy
# lifting of setting up the configuration in hive-site.xml 
# and setting up the MySQL instance (if necessary).
#
function deploy_hiveserver() 
{
	echo "Deploying Hive Metastore and Hiveserver2" | tee -a $LOG

	if [ -d /opt/mapr/hive ] ; then
    	HIVE_VER=$(cd /opt/mapr/hive; ls -d hive-*)
		HIVE_VER=${HIVE_VER#hive}
		HIVEMETA_PKG=mapr-hivemetastore${HIVE_VER}*
		HIVESERVER_PKG=mapr-hiveserver2${HIVE_VER}*
	else
		HIVEMETA_PKG=mapr-hivemetastore
		HIVESERVER_PKG=mapr-hiveserver2
	fi

		# We've seen many problems where the MySQL database
		# is corrupted by too-quick installations.   We'll 
		# go NICE AND SLOW.
	c yum install -y --disablerepo=* --enablerepo=MapR* $HIVEMETA_PKG

		# If the metastore does not come on line, bail out 
	wait_for_hive_service hivemeta 300
	[ $? -ne 0 ] && return

		# Install hiveserver2 (waiting for service to come on line)
	c yum install -y --disablerepo=* --enablerepo=MapR* $HIVESERVER_PKG
	wait_for_hive_service hs2 120

		# Make sure the database is properly initialized
		# Bug 13698 keeps showing up, where the metastore somehow
		# "double-taps" the MySQL service and loads two copies of
		# the exact same Hive schema; this trick seems to clean it up.
		#
	HIVE_HOME=$(ls -d /opt/mapr/hive/hive-*)
	metastore_jdbc=`grep jdbc:mysql $HIVE_HOME/conf/hive-site.xml`
	metastore_db=`basename "${metastore_jdbc%\?*}"`

	num_metastore_versions=`mysql -B $metastore_db --disable-column-names -e 'select count(VER_ID) from VERSION'`
	if [ ${num_metastore_versions:-1} -gt 1 ] ; then
		echo "INFO: cleaning up Hive metastore VERSION table" | tee -a $LOG
		mysql $metastore_db -e 'delete from VERSION where VER_ID != 1'
		if [ $? -eq 0 ] ; then
			maprcli node services -name hivemeta -action restart -filter "[service==hivemeta]"
			sleep 10
		fi
	fi
}

# Helper function ... deploy hiveserver only on "the last" node
# of a full stack deployment or on a stand-alone instance.
function deploy_cluster_hiveserver() 
{
	DB_PARAM_FILE=/tmp/maprdstore	# must match deploy-mapr-ami.sh setting

	if [ ! -f $DB_PARAM_FILE ] ; then
		echo "No dstore file ($DB_PARAM_FILE); will not configure hiveserver" | tee -a $LOG
		return
	fi

	THIS_HOST=`/bin/hostname`
	. $DB_PARAM_FILE
	dbhost=${dbhost:-DBHOST}
	dbhost_nodigits=`echo $dbhost | tr -d ".[0-9]"`
	if [ $dbhost = "localhost" ] ; then
		deploy_hiveserver
	elif [ -z "$dbhost_nodigits" ] ; then
		THIS_IP=`hostname -I`
		if [ -n "$dbhost" -a "$dbhost" = "$THIS_IP" ] ; then
			deploy_hiveserver
		fi
	else
		short_host=${THIS_HOST%%.*}
		short_dbhost=${dbhost%%.*}
		if [ -n "${short_dbhost}" -a "$short_dbhost" = "$short_host" ] ; then
			deploy_hiveserver
		fi
	fi	
}


# Deploy spark on webserver, resourcemanager, and historyserver nodes
# Deploy spark-historyserver only on job-historyserver nodes
#
function deploy_spark() 
{
	echo "Installing spark framework and history server"   | tee -a $LOG

	[ -f $MAPR_HOME/roles/webserver -o -f $MAPR_HOME/roles/resourcemanager  -o  -f $MAPR_HOME/roles/historyserver ] && \
		c yum install -y --disablerepo=* --enablerepo=MapR* mapr-spark

	[ -f $MAPR_HOME/roles/historyserver ] && \
		c yum install -y --disablerepo=* --enablerepo=MapR* mapr-spark-historyserver

	[ ! -d /opt/mapr/spark ] && return

	SPARK_HOME=$(ls -d /opt/mapr/spark/spark-*)

		# We'd love to create a separate volume, but there's already
		# and /apps directory so it's pain to create a volume and
		# mount it there.   
#	su $MAPR_USER -c "maprcli volume create -name apps_vol -path /apps"

	SJAR=$(ls $SPARK_HOME/lib/spark-assembly-*.jar)

	if [ -f $MAPR_HOME/roles/historyserver ] ; then
		su $MAPR_USER -c "hadoop fs -mkdir -p /apps/spark/lib"
		su $MAPR_USER -c "hadoop fs -chmod 777 /apps/spark"
		[ -f $SJAR ] && su $MAPR_USER -c "hadoop fs -put $SJAR /apps/spark/lib"
	fi

	SJAR=`basename $SJAR`
	SDEFAULTS=$SPARK_HOME/conf/spark-defaults.conf
	SLOGPROPS=$SPARK_HOME/conf/log4j.properties
	SHISTORYSERVER=$(maprcli node list -columns name -noheader -filter '[csvc==historyserver]' | awk '{print $1}')

		# Update spark-defaults.conf
		# No need to set historyserver.address on node where
		# where spark-historyserver has been installed ... 
		# only on other spark nodes
	echo "spark.yarn.jar    maprfs:///apps/spark/lib/$SJAR" >> $SDEFAULTS
	[ ! -f $MAPR_HOME/roles/historyserver  -a  -n "$SHISTORYSERVER" ] && \
		echo "spark.yarn.historyserver.address http://$SHISTORYSERVER:18080" >> $SDEFAULTS

	echo "log4j.rootCategory=WARN, console" >> $SLOGPROPS
	grep "appender.console" ${SLOGPROPS}.template >> $SLOGPROPS

		# Update Spark configuration to support Hive Metastore for Spark SQL
	HIVE_HOME=$(ls -d /opt/mapr/hive/hive-*)
	HIVE_VER_STRING=$(grep Version $HIVE_HOME/RELEASE_NOTES.txt | head -1)
	HIVE_VERSION="${HIVE_VER_STRING#*Version }"
	if [ -f $HIVE_HOME/conf/hive-site.xml ] ; then
		cp $HIVE_HOME/conf/hive-site.xml $SPARK_HOME/conf
		DIST_FILES=$HIVE_HOME/conf/hive-site.xml
	fi

	DNLIBS=$(ls $HIVE_HOME/lib/datanucleus-*.jar | paste -sd "," -)
	[ -n "$DNLIBS" ] && DIST_FILES=${DIST_FILES},$DNLIBS

		# Update spark-defaults.conf
		# No need to set historyserver.address on node where
		# where spark-historyserver has been installed ... 
		# only on other spark nodes
	echo "spark.yarn.jar    maprfs:///apps/spark/lib/$SJAR" >> $SDEFAULTS
	[ -n "$DIST_FILES" ] && \
		echo "spark.yarn.dist.files  $DIST_FILES" >> $SDEFAULTS
	[ -n "$HIVE_VERSION" ] && \
		echo "spark.sql.hive.metastore.version  $HIVE_VERSION" >> $SDEFAULTS

	[ ! -f $MAPR_HOME/roles/historyserver  -a  -n "$SHISTORYSERVER" ] && \
		echo "spark.yarn.historyserver.address http://$SHISTORYSERVER:18080" >> $SDEFAULTS

}


# We'll be using this a lot
DRILL_STORAGE_URL=http://localhost:8047/storage

# Configure a plugin if a configuration file exists
# ( ~mapr/cfg/<plugin>-drill-plugin.json )
#
function configure_drill_plugin() 
{
	PLUGIN_FILE=${MAPR_USER_DIR}/cfg/${1}-drill-plugin.json
	[ ! -f $PLUGIN_FILE ] && return

	echo "Configuring Drill plugin for $1"     | tee -a $LOG

	curl -X POST -H "Content-Type: application/json" \
	  --upload-file ${PLUGIN_FILE} \
	  ${DRILL_STORAGE_URL}/${1}.json   2>&1    | tee -a $LOG
	
	/bin/echo -e "\n" | tee -a $LOG
}

function deploy_drill() 
{
	echo "Deploying MapR Drill " | tee -a $LOG

	c yum install -y --disablerepo=* --enablerepo=MapR* mapr-drill
	[ $? -ne 0 ] && return

		# Warden will automatically start drill here ... a bit
		# of a problem given that we haven't adjusted the deployment

		# Adjust Drill config for Cloud
	echo "  and updating Drill configuration" | tee -a $LOG
	DRILL_HOME="$(ls -d /opt/mapr/drill/drill-*)"
	DRILL_ENV=$DRILL_HOME/conf/drill-env.sh
	DRILL_EXCLUDES=$DRILL_HOME/bin/hadoop-excludes.txt
	DRILL_OVERRIDE=$DRILL_HOME/conf/drill-override.conf

		# Limit drill memory on small instances
	MemKB=`grep MemTotal /proc/meminfo | awk '{print $2}'`
	if [ $MemKB -lt 15000000 ] ; then
		sed -i -e "s/DIRECT_MEMORY=\"8G\"/DIRECT_MEMORY=\"4G\"/" ${DRILL_ENV}
		sed -i -e "s/DRILL_MAX_HEAP=\"4G\"/DRILL_MAX_HEAP=\"2G\"/" ${DRILL_ENV}
	fi

		# Force centralized archving of query profiles 
	su $MAPR_USER -c "hadoop fs -mkdir -p /apps/drill"
	sed -i.bup 's!}$!,\nsys.store.provider.zk.blobroot: \"maprfs:///apps/drill\"\n}!' $DRILL_OVERRIDE
		
		# Lastly, enable S3 support (need credentials from core-site)
	sed -i -e "s/jets3t/#jets3t/" ${DRILL_EXCLUDES}

	if [ -f $HADOOP_CONF_DIR/core-site.xml ] ; then 
		if [ -f $DRILL_HOME/conf/core-site.xml ] ; then 
		  mv $DRILL_HOME/conf/core-site.xml $DRILL_HOME/conf/core-site.xml.orig
		fi
		ln -s $HADOOP_CONF_DIR/core-site.xml $DRILL_HOME/conf
	fi

	JETS3T_JAR="$(ls ${HADOOP_HOME}/share/hadoop/common/lib/jets3t-*.jar)"
	[ -f $JETS3T_JAR ] && \
		ln -s $JETS3T_JAR $DRILL_HOME/jars/3rdparty

		# Object Stores 
		#	AWS SDK jars needed to support s3 interfaces.
		#	Azure SDK jars needed to support WASB interfaces.
	TOOLS_LIB=${HADOOP_HOME}/share/hadoop/tools/lib
	for f in ${TOOLS_LIB}/*aws* ; do
		jar=`basename $f`
		if [ ! -r $DRILL_HOME/jars/3rdparty/$jar ] ; then
			ln -s $f $DRILL_HOME/jars/3rdparty
		fi
	done

	for f in ${TOOLS_LIB}/*azure* ; do
		jar=`basename $f`
		if [ ! -r $DRILL_HOME/jars/3rdparty/$jar ] ; then
			ln -s $f $DRILL_HOME/jars/3rdparty
		fi
	done

		# Make sure service is registered with warden
		# Restart the service to incorporate our changes above
		#	NOTE: while "maprcli" should work to restart the service,
		#	we've seen numerous examples in cloud deployments where
		#	warden does not acknowledge that the service is running.
		#	Hard-code the drillbit script for now.
	$MAPR_HOME/server/configure.sh -R		# force reload of services
#	maprcli node services -name drill-bits -action restart -nodes `cat /opt/mapr/hostname`
	su $MAPR_USER -c "${DRILL_HOME}/bin/drillbit.sh restart"
	[ $? -eq 0 ] && sleep 10

		# Configure the Drill plug-ins (after drill on-line)
	echo "  and, lastly, adding storage plug-ins" | tee -a $LOG

	DRILL_WAIT=300

	SWAIT=$DRILL_WAIT
	STIME=3
	curl -f $DRILL_STORAGE_URL &> /dev/null
	while [ $? -ne 0  -a  $SWAIT -gt 0 ] ; do
		sleep $STIME
		SWAIT=$[SWAIT - $STIME]
		curl -f $DRILL_STORAGE_URL &> /dev/null
	done

		# Bail out if Drill never came on line
	if [ $SWAIT -lt 0 ] ; then
		echo "WARNING: drillbit did not come on-line" | tee -a $LOG
		return
	fi

	configure_drill_plugin maprdb
	configure_drill_plugin s3amplab
	configure_drill_plugin wasbmaprpublic

	[ ! -f /opt/mapr/roles/hivemetastore ] && return

	THIS_HOST=`/bin/hostname`
	HIVE_PLUGIN_FILE=${MAPR_USER_DIR}/cfg/hive-drill-plugin.json
	if [ -f $HIVE_PLUGIN_FILE ] ; then
		sed -i -e "s/METASTOREHOST/$THIS_HOST/" $HIVE_PLUGIN_FILE
		configure_drill_plugin hive
	fi
}

# There may be some data in "workloads" that we'll copy up to
# the hadoop cluster (if we have a location)
function stage_drill_data() 
{
	hadoop fs -test -d /data
	[ $? -ne 0 ] && return

	ls ${MAPR_USER_DIR}/workloads/drill/*.json &> /dev/null
	[ $? -ne 0 ] && return

	for f in ${MAPR_USER_DIR}/workloads/drill/*.json 
	do
		su $MAPR_USER -c "hadoop fs -put $f /data"
	done
}

function main() 
{
	echo "$0 script started at "`date`   | tee -a $LOG
	echo "    with args: $@"             | tee -a $LOG
	echo "    executed by: "`whoami`     | tee -a $LOG
	echo "    \$Revision: $"             | tee -a $LOG
	echo "    \$Date: $"                 | tee -a $LOG
	echo ""                              | tee -a $LOG

	hadoop fs -stat /  &> /dev/null
	if [ $? -ne 0 ] ; then
		echo "ERROR : Cluster not running "  | tee -a $LOG
		echo "   no actions taken"           | tee -a $LOG
	else
		while [ $# -gt 0 ] ; do
			case "$1" in 
				hiveserver)
					deploy_cluster_hiveserver
					;;
				spark)
					deploy_spark
					;;
				drill)
					deploy_drill
					stage_drill_data
					;;
				*)
					echo "WARNING: unrecognized service $1" | tee -a $LOG
					;;
			esac
			shift 
		done
	fi

	echo "$0 script completed at "`date` | tee -a $LOG
	return 0
}

main $@
exitCode=$?

# Save log to ~${MAPR_USER} ... since Ubuntu images erase /tmp
if [ -n "${MAPR_USER_DIR}"  -a  -d "${MAPR_USER_DIR}" ] ; then
		cp $LOG $MAPR_USER_DIR
		chmod a-w ${MAPR_USER_DIR}/`basename $LOG`
		chown $MAPR_USER:$MAPR_GROUP ${MAPR_USER_DIR}/`basename $LOG`
fi

exit $exitCode
