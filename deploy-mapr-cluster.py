#!/opt/mapr/installer/build/python/bin/python
#
#   local python     #!/usr/bin/env python
#
#   NOTE: Requires Python 2.7 and "requests" package
#
# Usage
#
# Exit Codes :
#   0 : Success (or interactive decision to abort)
#   1 : Failure : Failed initialization phase (INIT)
#   2 : Failure : Cluster validation failed (CHECK phase)
#   3 : Failure : INSTALLATION failed
#
# Important details about defaults
#   There are multiple levels of attribute defaults in this
#   script.  The MIDriver class __could__ be leveraged elsewhere, 
#   so it has a simple set of defaults:
#       installer_url = https://localhost:9443
#       mapr_version : 5.0.0
#       mapr_edition = 'M3'
#       mapr_user = mapr
#       mapr_password = mapr
#       cluster = 'my.cluster.com'
#       ecosystem defaults
#           { 'drill' : '1.2', 'hbase' : '0.98', 'hive' : '1.2', 'pig' : '0.14' }
#
#   The command line parsing also has some defaults ... which 
#   help when setting up the driver object in this temp wrapper.
#       installer_url = https://localhost:9443
#       mapr_version : 5.0.0
#       mapr_edition = 'M3'
#       mapr_user = mapr
#       mapr_password = MapR
#       cluster = 'MyCluster'
#       ssh-user = 'ec2-user'
#
# TBD
#   Add logic to support "--eco-verison <product>=latest" ... for latest 
#   supported version.


import os
import sys
import subprocess
import argparse
import datetime
import time
import ssl
import requests,json
requests.packages.urllib3.disable_warnings()

import logging
import logging.config 

__author__ = "MapR"
 

# We'll use this struct to initialize logging below.
# We accept command line options to set log level and output file.
#
#   We can't be smarter about the logfile here.
#   See below for how we handle overriding the default location.
#
logging_config = dict(
    version = 1,
    formatters = {
        'f_console': {'format':
              '%(name)-12s %(levelname)-8s %(message)s'},
        'f_file': {'format':
              '%(asctime)s %(name)-12s %(levelname)-8s %(message)s'}
        },
    handlers = {
        'ch': {'class': 'logging.StreamHandler',
              'stream': 'ext://sys.stdout',
              'formatter': 'f_console',
              'level': logging.DEBUG},
        'fh': {'class': 'logging.FileHandler',
              'filename': '/tmp/dmc.log',
              'formatter': 'f_file',
              'level': logging.INFO}
        },
    loggers = {
        '': {'handlers': ['ch', 'fh'],
                 'level': logging.DEBUG},
        'root': {'handlers': ['ch', 'fh'],
                 'level': logging.DEBUG},
        'app': {'handlers': ['ch','fh'],
                 'level': logging.INFO}
        }
)


# Simple class to drive the MapR Installer service
class MIDriver:
    def __init__(self, url="https://localhost:9443", user="mapr", passwd="mapr") :
            # All our REST traffic to the Installer uses these headers
        self.headers = { 'Content-Type' : 'application/json' } 
        self.installer_url = url
        self.installer_session = requests.Session()
        self.mapr_user = user
        self.mapr_password = passwd
        self.cluster = 'my.cluster.com'
        self.mapr_version = '5.0.0'
        self.mapr_edition = 'M3'
        self.eco_defaults = { 'drill' : '1.2', 'hbase' : '0.98', 'hive' : '1.2', 'pig' : '0.14' }
        self.disks = []
        self.hosts = []
        self.services = {}
        self.ssh_user = None
        self.ssh_password = None
        self.ssh_key = None
        self.portal_user = None
        self.portal_password = None
        self.stage_user = None
        self.stage_password = None
        self.stage_license_url = "http://stage.mapr.com/license"

        self.silent_running = False

            # State variables from REST interface
        self.current_state = None
        self.license_uploaded = False

            # And our logger (use global default logger for now)
        self.logger = logging.getLogger()

        # Disable status messages during load
    def setSilentRunning (self, newSilent) :
        if newSilent == True :
            self.silent_running = True
        elif newSilent == False :
            self.silent_running = False

        # TBD : Be smarter for setting cluster and edition
        #   check for 0-lenghth string or list.
    def setClusterName(self, newName) :
        if newName != None :
            self.cluster = newName

    def setEdition(self, newEdition) :
        if newEdition != None :
            if newEdition.lower()  == 'm3' or newEdition.lower() == 'community' :
                self.mapr_edition = 'M3'
            elif newEdition.lower()  == 'm5' or newEdition.lower() == 'enterprise' :
                self.mapr_edition = 'M5'
            elif newEdition.lower()  == 'm7' or newEdition.lower() == 'database' :
                self.mapr_edition = 'M7'

    def setSshCredentials(self, newUser, newKey, newPassword) :
        if newUser != None : 
            self.ssh_user = newUser
        if newKey != None : 
            self.ssh_key = newKey
        if newPassword != None : 
            self.ssh_password = newPassword

    def setPortalCredentials(self, newUser, newPassword) :
        if newUser != None : 
            self.portal_user = newUser
        if newPassword != None : 
            self.portal_password = newPassword

    def setStageCredentials(self, newUser, newPassword) :
        if newUser != None : 
            self.stage_user = newUser
        if newPassword != None : 
            self.stage_password = newPassword

    def setHosts(self, newHosts) :
        self.logger.debug ("MIDriver::setHosts(%s)", ','.join(newHosts))
        if newHosts != None :
            self.hosts = newHosts
            self.logger.debug ("  self.hosts = %s", ','.join(self.hosts))

    def setDisks(self, newDisks) :
        self.logger.debug ("MIDriver::setDisks(%s)", ','.join(newDisks))
        if newDisks != None :
            self.disks = newDisks
            self.logger.debug ("  self.disks = %s", ','.join(self.disks))

    def swagger_get(self,target) :
        self.logger.debug ("MIDriver::swagger_get(%s)", target)
        errcnt = 0
        while errcnt < 5 :
            try :
                r = self.installer_session.get(self.installer_url + target,
                    auth = (self.mapr_user, self.mapr_password),
                    headers = self.headers,
                    verify = False)
            except requests.ConnectionError :
                errcnt += 1
                self.logger.debug ("  connection error %d", errcnt)
            else :
                self.logger.debug ("  rval: "+json.dumps(r.json(),indent=4,sort_keys=True))
                return r

    def swagger_patch(self, target, payload) :
        self.installer_session.patch(self.installer_url + target,
                auth = (self.mapr_user, self.mapr_password),
                headers = self.headers,
                verify = False,
                data = json.dumps(payload))

    def config_get(self) :
        return self.swagger_get("/api/config")

    def config_patch(self, payload) :
        self.swagger_patch ("/api/config", payload)

    def process_get(self) :
        return self.swagger_get("/api/process")

    def process_patch(self,payload) :
        self.swagger_patch ("/api/process", payload)

    def services_get(self,payload=None) :
        r = self.installer_session.get(self.installer_url + "/api/services",
                auth = (self.mapr_user, self.mapr_password),
                headers = self.headers,
                params = payload, 
                verify = False)
        return r

    def service_available(self,sname,sversion) :
        payload = { 'name' : "mapr-"+sname, 'version' : sversion } 
        r = self.services_get (payload)
        return ( r.json()['count'] != 0 )

    def get_service_hosts(self,sname,sversion) :
        payload = { 'name' : "mapr-"+sname, 'version' : sversion } 
        r = self.services_get (payload)
        return ( r.json()['resources'][0]['hosts'] )

        # For services that have defined ui ports, this
        # routine assemples a list of "host:port" to return
    def get_service_url(self,sname,sversion) :
        payload = { 'name' : "mapr-"+sname, 'version' : sversion } 
        r = self.services_get (payload)
        resources=r.json()['resources'][0]

        urls = []
        for h in resources['hosts'] :
            if 'ui_ports' in resources : 
                for p in resources['ui_ports'] :
                    urls.append(h+':'+str(p))
            else :
                urls.append(h)

        return ( urls )


    def initializeCoreServicesList (self, mapr_version = None) :
        if mapr_version != None:
            self.mapr_version = mapr_version
        self.services = {}

            # MapR core YARN stuff (forget MRv1 for now)
        self.services["mapr-core"] = { "enabled" : True, "version" : self.mapr_version }
        self.services["mapr-cldb"] = { "enabled" : True, "version" : self.mapr_version }
        self.services["mapr-fileserver"] = { "enabled" : True, "version" : self.mapr_version }
        self.services["mapr-nodemanager"] = { "enabled" : True, "version" : self.mapr_version }
        self.services["mapr-resourcemanager"] = { "enabled" : True, "version" : self.mapr_version }
        self.services["mapr-historyserver"] = { "enabled" : True, "version" : self.mapr_version }
        self.services["mapr-webserver"] = { "enabled" : True, "version" : self.mapr_version }
        self.services["mapr-zookeeper"] = { "enabled" : True, "version" : self.mapr_version }

        # Always include NFS service
        self.services["mapr-nfs"] = { "enabled" : True, "version" : self.mapr_version }


    def initializeEcoServicesList (self) :
        ver = self.eco_defaults.get('hbase')
        if ver != None : 
            self.addMapRDBServices (ver)

        ver = self.eco_defaults.get('hive')
        if ver != None : 
            self.addHiveServices (ver)

        ver = self.eco_defaults.get('spark')
        if ver != None : 
            self.addSparkServices (ver)

        ver = self.eco_defaults.get('pig')
        if ver != None : 
            self.addEcoServices ('pig', ver)

        ver = self.eco_defaults.get('drill')
        if ver != None : 
            self.addEcoServices ('drill', ver)


        # MapRDB
    def addMapRDBServices (self, hbase_version = None) :
        if hbase_version == None :
            hbase_version = self.eco_defaults.get('hbase', "0.98")
        elif hbase_version.lower() == "none" :
            if 'mapr-hbase' in self.services :
                del self.services['mapr-hbase']
            if 'mapr-hbasethrift' in self.services :
                del self.services['mapr-hbasethrift']
            if 'mapr-libhbase' in self.services :
                del self.services['mapr-libhbase']
            return
        elif self.service_available ('hbase', hbase_version) == False : 
            hbase_version = self.eco_defaults.get('hbase', "0.98")

        self.services["mapr-hbase"] = { "enabled" : True, "version" : hbase_version }
#        self.services["mapr-hbasethrift"] = { "enabled" : True, "version" : hbase_version }
        self.services["mapr-libhbase"] = { "enabled" : True, "version" : hbase_version }


        # Hive (with only local MySQL supported for now)
    def addHiveServices (self, hive_version = None, hive_user = None, hive_password = None, hive_db = "local") :
        if hive_version == None :
            hive_version = self.eco_defaults.get('hive', "1.2")
        elif hive_version.lower() == "none" :
            if 'mapr-mysql' in self.services :
                del self.services['mapr-mysql']
            if 'mapr-hive-client' in self.services :
                del self.services['mapr-hive-client']
            if 'mapr-hivemetastore' in self.services :
                del self.services['mapr-hivemetastore']
            if 'mapr-hiveserver2' in self.services :
                del self.services['mapr-hiveserver2']
            return
        elif self.service_available ('hive', hive_version) == False : 
            hive_version = self.eco_defaults.get('hive', "1.2")

        if hive_db == 'local' :
            self.services["mapr-mysql"] = { "enabled" : True }
            if hive_user == None :
                hive_user = self.mapr_user
            if hive_password == None :
                hive_password = self.mapr_password
            db_name = "hive_" + hive_version.replace(".","")

            HIVE_DATABASE = { "type" : "MYSQL", "create" : True, "name" : db_name, "user" : hive_user, "password" : hive_password }
        else :
            HIVE_DATABASE = { "type" : "MYSQL", "create" : False, "name" : hive_db, "user" : hive_user, "password" : hive_password }

        self.services["mapr-hive-client"] = { "enabled" : True, "version" : hive_version}
        self.services["mapr-hiveserver2"] = { "enabled" : True, "version" : hive_version}
        self.services["mapr-hivemetastore"] = { "enabled" : True, "database" : HIVE_DATABASE, "version" : hive_version }
    
        # Spark service
    def addSparkServices (self, spark_version = None) :
        if spark_version == None :
            spark_version = self.eco_defaults.get('spark', "1.2.1")
        elif spark_version.lower() == "none" :
            if 'mapr-spark-client' in self.services :
                del self.services['mapr-spark-client']
            if 'mapr-spark-historyserver' in self.services :
                del self.services['mapr-spark-historyserver']
            return
        elif self.service_available ('spark', spark_version) == False : 
            spark_version = self.eco_defaults.get('spark', "1.2.1")

        self.services["mapr-spark-client"] = { "enabled" : True, "version" : spark_version }
        self.services["mapr-spark-historyserver"] = { "enabled" : True, "version" : spark_version }

        # Basic ecosystem service ... no extra work for config
    def addEcoServices (self, eco_service = None, eco_version = None) :
        svc = 'mapr-' + eco_service

        if eco_version == None  or  eco_version == None :
            return
        elif eco_version.lower() == "none" :
            if svc in self.services :
                del self.services[svc]
            return

        if self.service_available (eco_service, eco_version) == False :
            return

        self.services[svc] = { "enabled" : True, "version" : eco_version}


    def initializeClusterConfig(self) :
        self.logger.debug ("MIDriver::initializeClusterConfig()")
        payload = { 'cluster_admin_password' : self.mapr_password } 
        self.config_patch(payload)

        payload = { 'cluster_name' : self.cluster } 
        self.config_patch(payload)

        payload = { 'ssh_id' : self.ssh_user }
        self.config_patch(payload)
        if self.ssh_key != None :
            self.config_patch ( {'ssh_key' : self.ssh_key} )
        elif self.ssh_password != None :
            self.config_patch ( {'ssh_password' : self.ssh_password} )

            # The installer service defaults to the
            # running host, so if nothing has been specified 
            # we're still OK
        if len(self.hosts) > 0 : 
            payload = { 'hosts' : self.hosts } 
            self.config_patch(payload)

        if len(self.disks) > 0 :
            payload = { 'disks' : self.disks }
            self.config_patch(payload)
        else :
            self.logger.warn ("initializeClusterConfig called when no disks were specified")

        # For automated license installation, we'll use an internal
        # account (as a temporary workaround)
        payload = { 'license_type' : self.mapr_edition } 
        self.config_patch(payload)
        
        if self.portal_user != None   and  self.portal_password != None :
            payload = { 'mapr_name' : self.portal_user, 'mapr_password' : self.portal_password } 
            self.config_patch(payload)

#            payload = { 'licenseType' : self.mapr_edition, 'licenseValidation' : 'INSTALL' } 
#            self.config_patch(payload)

        # Specify the services
        payload = { 'services' : self.services } 
        self.config_patch(payload)

        # Last, but not least, add stage license (if necessary)
        self.configureTrialLicense()

            # Print out the message config for sanity 
            # (long term, we'll drop this)
        r = self.config_get()
        if self.silent_running == False :
            self.logger.info ("\n"+json.dumps(r.json(),indent=4,sort_keys=True))

            # Handle the case where a CHECK has failed and
            # we're just trying again
        rc = self.waitForProcessState( 'INIT' )
        if rc == False :
            if self.current_state[0:5] == "CHECK" :
                rc = True
            elif self.current_state == "PROVISIONED" :
                rc = True
            elif self.current_state[-5:] == "ERROR" :
                rc = True

        return rc


        # The default service provisioning can leave "gaps";
        # fix those here.
        #   1.  node0 always has webserver 
        #   2.  all nodes have fileserver/nodemanager/nfs
        #       (makes sense for even 6-10 node clusters in the cloud)
    def updateClusterConfig(self) :
        self.logger.debug ("MIDriver::updateClusterConfig")
        self.logger.debug ("  hosts:"+','.join(self.hosts))

            # webserver
        svc_target="/api/services/"+"mapr-webserver-"+self.mapr_version
        self.swagger_patch (svc_target, {"hosts" : self.hosts[0]})

            # fileserver
        svc_target="/api/services/"+"mapr-fileserver-"+self.mapr_version
        self.swagger_patch (svc_target, {"hosts" : self.hosts})

            # nodemanager
        if 'mapr-nodemanager' in self.services :
            svc_target="/api/services/"+"mapr-nodemanager-"+self.mapr_version
            self.swagger_patch (svc_target, {"hosts" : self.hosts})

            # hive-client, pig, and spark-client (on all nodes)
        for s in ["hive-client", "pig", "drill", "spark-client" ] :
            svc = "mapr-" + s
            if svc in self.services :
                ver = self.services[svc].get("version")
                svc_target="/api/services/"+svc+"-"+ver
                self.swagger_patch (svc_target, {"hosts" : self.hosts})


        # If access to the license stage repository has
        # been specified, download trial license and 
        # put into the configuration.
    def configureTrialLicense(self) :
        if self.stage_user == None  or  self.mapr_edition == 'M3' :
            return 

        self.logger.info ( "configureTrialLicense: user %s for edition %s", self.stage_user, self.mapr_edition )

        license_url = self.stage_license_url + "/LatestDemoLicense-" + self.mapr_edition + ".txt"

        license = requests.get(license_url,
                auth = (self.stage_user, self.stage_password),
                headers = { 'Content-Type' : 'text/plain' }) 

        if license.reason != 'OK' :
            self.logger.info ( "Failed to retrieve trial license" )
            return False

        self.config_patch ( {'license' : license.text} )
        self.license_uploaded = True


        # Return success when state is reached.
        # If state returns anything other than $tgtState 
        # or ${tgtState%ING}ED, return failure
        #
    def waitForProcessState (self,tgtState, maxWait=600, waitInterval=5) :
        while ( maxWait > 0 ) :
            r = self.process_get()
            curState = r.json()['state']
            if ( curState == tgtState ) :
                break
            elif ( curState == tgtState.replace('ED', 'ING')) :
                curTime = datetime.datetime.now()
                timeHdr = datetime.datetime.strftime (curTime, "%H:%M:%S")
                if self.silent_running == False :
                    self.logger.info ("%s  : Waiting for %s (current state %s)", timeHdr, tgtState, curState )
                    sys.stdout.flush()

                maxWait -= waitInterval
                time.sleep(waitInterval)
            else :
                maxWait = 0
                break

        if self.silent_running == False :
            self.logger.info ( "Installer state %s", curState )
            sys.stdout.flush()

        self.current_state = curState 
        return (maxWait > 0) 


    def checkClusterConfig(self) :
        self.logger.debug ("MIDriver::checkClusterConfig()")
        if self.hosts == None :
            logger.critical ("No hosts specified")
            return (False)

        if self.disks == None  or  len(self.disks) <= 0 :
            logger.critical ("No disks specified")
            return (False)

        payload = { 'state' : 'CHECKING' } 
        self.process_patch (payload)
        rc = self.waitForProcessState( 'CHECKED' )
        if rc != True :
            return (rc)

        payload = { 'state' : 'PROVISIONING' } 
        self.process_patch (payload)
        rc = self.waitForProcessState( 'PROVISIONED' )
        if rc != True :
            return (rc)

        self.updateClusterConfig()

            # Print out the cluster's config for sanity 
            # (long term, we'll drop this)
        if self.silent_running == True :
            self.printCoreServiceLayout()

        return (True)

    def doInstall(self) :
        self.logger.debug ("MIDriver::doInstall()")

            # Handle case were earlier invocation has
            # left us in INSTALL_ERROR state and we should
            # simply retry the install.   This happens in
            # cloud environments when ssh connections time out
        if self.current_state == "INSTALL_ERROR" :
            payload = { 'state' : 'RETRYING' } 
        else :
            payload = { 'state' : 'INSTALLING' } 
        self.process_patch (payload)
        rc = self.waitForProcessState( 'INSTALLED' , 5400, 20)
        if rc != True :
            return (rc)

        if self.license_uploaded == True :
            payload = { 'state' : 'LICENSING' } 
            self.process_patch (payload)
            rc = self.waitForProcessState( 'LICENSED' , 120, 10)
            if rc != True :
                return (rc)

        payload = { 'state' : 'COMPLETED' } 
        self.process_patch (payload)
        self.waitForProcessState( 'COMPLETED' , 10, 10)
        return (True)

    def printCoreServiceLayout(self, svc_list=["zookeeper","cldb","fileserver","nodemanager","resourcemanager" ]) :
        self.logger.info ("")
        self.logger.info ("Cluster Services Configuration: ")
        for svc in svc_list :
            svc_hosts = self.get_service_hosts (svc, self.mapr_version)
            self.logger.info (svc + ": " + ','.join(svc_hosts))
        self.logger.info ("")
        sys.stdout.flush()

    def printMCS(self) :
        mcs_hosts = self.get_service_hosts ('webserver', self.mapr_version)
        self.logger.info ("MCS console(s) available at:")
        for h in mcs_hosts :
            self.logger.info ("    https://"+h+":8443") 
        sys.stdout.flush()

    def printSuccessUrl(self) :
        self.logger.info ("MapR Installer Service available at "+self.installer_url+"/#/complete") 
        sys.stdout.flush()

# Variable we should be grabbing based on customer input or deployment infrastructure
#    To Be Done
#       Correctly handle "remote" vs "local" invocation, so as
#       to better handle the need to specify "disks" (or simply
#       look it up).
#
#       Convert to it's own class (to avoid global namespace issues)
#
#       Improve "wait for state" logic to error out on warnings
#       
#       Add interactive verification of parameters.
#
#
MAPR_USER = "mapr"
MAPR_PASSWD = "MapR"
# DISKS=[ "/dev/xvdf" ]


def query_yes_no(question, default="yes"):
    """Ask a yes/no question via raw_input() and return their answer.

    "question" is a string that is presented to the user.
    "default" is the presumed answer if the user just hits <Enter>.
        It must be "yes" (the default), "no" or None (meaning
        an answer is required of the user).

    The "answer" return value is True for "yes" or False for "no".
    """
    valid = {"yes": True, "y": True, "ye": True,
             "no": False, "n": False}
    if default is None:
        prompt = " [y/n] "
    elif default == "yes":
        prompt = " [Y/n] "
    elif default == "no":
        prompt = " [y/N] "
    else:
        raise ValueError("invalid default answer: '%s'" % default)

    while True:
        sys.stdout.write(question + prompt)
        choice = raw_input().lower()
        if default is not None and choice == '':
            return valid[default]
        elif choice in valid:
            return valid[choice]
        else:
            sys.stdout.write("Please respond with 'yes' or 'no' "
                             "(or 'y' or 'n').\n")


# Handle our command line
def gatherArgs () :
    parser = argparse.ArgumentParser(formatter_class=argparse.ArgumentDefaultsHelpFormatter)

    parser.add_argument("-q","--quiet", default=False, action="store_true",
        help="Execute silently, without any status output")
    parser.add_argument("-y","--yes", default=False, action="store_true",
        help="Execute without prompting user (status messages will still be printed).")
    parser.add_argument("-l", "--log-level", default="INFO",
        help="Relative logging level (DEBUG,INFO,WARN,ERROR,CRITICAL")
    parser.add_argument("--log-file", 
        help="log file for this execution")
    parser.add_argument("--cluster", default="MyCluster",
        help="Cluster name")
    parser.add_argument("--mapr-version", default="5.0.0",
        help="MapR Software Version")
    parser.add_argument("--mapr-edition", default="M3",
        help="MapR License Edition (M3 {community}, M5 {enterprise}, or M7 {database})")
    parser.add_argument("--mapr-user", default="mapr",
        help="MapR admin user")
    parser.add_argument("--mapr-password", default="MapR",
        help="password for MapR admin user")
    parser.add_argument("--installer-url", default="https://localhost:9443",
        help="URI for MapR installer service")
    parser.add_argument("--ssh-user", default="ec2-user",
        help="ssh user for system access")
    parser.add_argument("--ssh-keyfile", 
        help="ssh private key file")
    parser.add_argument("--ssh-password",
        help="password for ssh user (if no key file is given)")
    parser.add_argument("--portal-user",
        help="Registered user for mapr.com portal *** UNSUPPORTED *** ")
    parser.add_argument("--portal-password",
        help="Password for portal user *** UNSUPPORTED *** ")
    parser.add_argument("--stage-user", 
        help="Registered username for retrieving demo licenses from  stage.mapr.com/license")
    parser.add_argument("--stage-password", 
        help="Password for stage user")
    parser.add_argument("--disks",
        help="Comma-separate list of disks for MapR-FS on cluster nodes")
    parser.add_argument("--disks-file",
        help="File containing disks for MapR-FS (one disk per line)")
    parser.add_argument("--hosts",
        help="Comma-separate list of hosts on which to deploy MapR")
    parser.add_argument("--hosts-file",
        help="File containing hosts (one host per line)")
    parser.add_argument("--eco-version", nargs='*', action='append',
        help="Desired versions of esystem comments; format is <pkg>=<ver> (use multiple times for multiple components)")

    args = parser.parse_args()
    return (args)


# Read in hosts/disks file.  If file doesn't exist, simply return
# empty list (we should do better here).
# NOTE:
#   This is of the form it is to handle the legacy condition where
#   the list of hosts is generated by the Amazon Cloud Formation 
#   template (and the host name is accompanied by other info for
#   assisting in system configuration).  For disks lists, this
#   is actually overkill ... but cleaner to have a single 
#   framework.
def genItemsList (itemsFile) :
    items = [] 

    if not os.path.isfile(itemsFile) :
        return (items)

        # Careful with Popen here.   The "$1" in the awk command
        # needs to make it all the way through the shell invocation,
        # and that was a bit problematic.
    proc = subprocess.Popen('/usr/bin/env awk "{print \$1}" '+itemsFile, shell=True, stdout=subprocess.PIPE)

    while ( True ) :
        nextItem = proc.stdout.readline() 
        if nextItem == '' :
            break
        else :
            nextItem = nextItem.rstrip()

        if ( len (nextItem) > 0 ) :
            items.append (nextItem)

    return (items)


# Expand the arguments that need expanding just in case.
# Actual validation of will be done in the MIDriver class
# (since we can set some rational defaults there)
#
#   TBD : log rational errors if files specified but not found
def checkArgs (argList) :
    if argList.hosts == None  and  argList.hosts_file != None :
        if os.path.isfile(argList.hosts_file) :
            argList.hosts = genItemsList (argList.hosts_file)
    else :
        newHosts = argList.hosts.split(",")
        argList.hosts = newHosts

    if argList.disks == None  and  argList.disks_file != None :
        if os.path.isfile(argList.disks_file) :
            argList.disks = genItemsList (argList.disks_file)
    else :
        newDisks = argList.disks.split(",")
        argList.disks = newDisks

        # Extract key file (if possible)
    if argList.ssh_keyfile != None : 
        if os.path.isfile(argList.ssh_keyfile) :
            with open (argList.ssh_keyfile, "r") as keyfile:
                ssh_key = keyfile.read()
            argList.ssh_key = ssh_key

    return argList



#  logging.basicConfig(filename="/tmp/dmc.log", level=logging.INFO, filemode="w")

logging.config.dictConfig(logging_config)
logger = logging.getLogger()
logger.info('Launching deploy-mapr-cluster.py')


# Parse our command line (tough to log to an external file at this point)
myArgs = gatherArgs()

# Set log file and level (since we just parsed them
# from the the command line args).
#   NOTE: This logic only works for a SINGLE FileHandler
#   object within our logger.
sLogFile = myArgs.log_file
if sLogFile != None  and  os.access(os.path.dirname(sLogFile), os.W_OK) :
    formatter = None
    for hdlr in logger.handlers :
        if isinstance (hdlr, logging.FileHandler) :
            formatter = hdlr.formatter
            logger.removeHandler (hdlr)

    if formatter == None :
        formatter = logging.Formatter('%(asctime)s %(name)-12s %(levelname)-8s %(message)s')

    newh = logging.FileHandler(sLogFile)
    newh.setFormatter(formatter)
    logger.addHandler (newh)
    logger.info ("Log output file set to %s", sLogFile)

iLogLevel = getattr (logging, myArgs.log_level.upper(), None)
if not isinstance (iLogLevel, int) :
    logger.info('Invalid log level (%s)', myArgs.log_level)
else :
    logger.setLevel(iLogLevel)
    logger.info('Log level set to %s', myArgs.log_level)


# Next, so some minimal error checking and variable expansion
checkedArgs = checkArgs (myArgs)

    # Convert Namespace to a Dictionary (to get rid of our
    # "null" values" and allow iteration).  For now, this is just debug
    #   Mask out ssh_key and account passwords
    #   NOTE: must be a new object, otherwise we overwrite checkedArgs)
argDict = dict(vars(checkedArgs))
pentry = argDict.pop ('ssh_key', None)
if pentry != None :
    argDict['ssh_key'] = pentry[:8]+'...'

for pkey in [ 'mapr_password', 'ssh_password', 'portal_password', 'stage_password' ] :
    pentry = argDict.pop (pkey, None)
    if pentry == None :
        argDict[pkey] = None                # leave empty entry in dict
    else :
        argDict[pkey] = '********'

logger.debug ("Launching MIDriver with these arguments:")
logger.debug ("\n"+json.dumps(argDict,indent=4,sort_keys=True))

# cont = query_yes_no ("Continue with installation ?", "no")
# if cont != True :
#     exit (0)


# TBD Change design to throw exception if the installer is not found
driver = MIDriver (checkedArgs.installer_url, checkedArgs.mapr_user, checkedArgs.mapr_password)

# Simplified logic
#
driver.setClusterName (checkedArgs.cluster)
driver.setEdition (checkedArgs.mapr_edition)
driver.setSshCredentials (
    getattr(checkedArgs,'ssh_user', None), 
    getattr(checkedArgs,'ssh_key', None), 
    getattr(checkedArgs,'ssh_password', None)) 
driver.setPortalCredentials (
    getattr(checkedArgs,'portal_user', None), 
    getattr(checkedArgs,'portal_password', None)) 
driver.setStageCredentials (
    getattr(checkedArgs,'stage_user', None), 
    getattr(checkedArgs,'stage_password', None)) 
driver.setHosts (checkedArgs.hosts)
driver.setDisks (checkedArgs.disks)
driver.setSilentRunning (checkedArgs.quiet)

    # There is certainly a better way to handle this,
    # but at least this works.
eco_versions={}
eco_overrides = getattr(checkedArgs, 'eco_version', None)
if eco_overrides != None : 
    for el in eco_overrides :
        entry = el[0].split ('=')
        eco_versions[entry[0]] = entry[1]

logger.debug ("Ecosystem Package Overrides: "+json.dumps(eco_versions))

# Set up services ... could be much smarter here 
#   (especially about the versioning for each service).
#   Problem is that passing "None" in while we're deciding we 
#   want to load the services should use the default
#
driver.initializeCoreServicesList (checkedArgs.mapr_version)
driver.initializeEcoServicesList ()

ver = eco_versions.get('hbase')
if ver != None : 
    driver.addMapRDBServices (ver)

ver = eco_versions.get('hive')
if ver != None : 
    driver.addHiveServices (ver)

ver = eco_versions.get('spark')
if ver != None : 
    driver.addSparkServices (ver)

# All the ecosystem projects that DO NOT require
# complex config, we'll just handle here.
#   TBD : be smarter about the svc list and
#   walk through everything in eco_versions.
#
for svc in { 'pig', 'drill', 'hue', 'oozie' } :
    ver = eco_versions.get(svc)
    if ver != None : 
        driver.addEcoServices (svc, ver)


operationOK = driver.initializeClusterConfig()
if operationOK == True :
    if checkedArgs.yes == False : 
        cont = query_yes_no ("Configuration uploaded; continue with CHECKING ?", "yes")
        if cont != True :
            exit (0)
else :
    logger.error ( "Failed to initialized installer services; aborting" )
    exit (1)

# If the Installer service is in "INSTALL_ERROR" mode, we should
# skip the checkClusterConfig step and just "retry" the install.
# The doInstall routine handles that logic.
#
if driver.current_state != "INSTALL_ERROR" :
    operationOK = driver.checkClusterConfig()
    if operationOK == True :
        if checkedArgs.yes == False : 
            cont = query_yes_no ("Configuration validated; continue with INSTALL ?", "yes")
            if cont != True :
                exit (0)
    else :
        logger.error ( "Failed to validate configuration; aborting" )
        exit (2)

operationOK = driver.doInstall()
if operationOK == False :
    logger.error ( "Failed to complete cluster installation; aborting" )
    exit (3)

if checkedArgs.quiet == False : 
    logger.info ( "" )
    driver.printSuccessUrl()
    driver.printMCS()

logger.info('deploy-mapr-cluster.py completed')
exit (0)
