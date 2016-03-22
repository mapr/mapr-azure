# MapR Installer Driver Class (MIDriver)
#
# Simple class to drive the MapR Installer service
#
# Usage : 
#   See the deploy-mapr-cluster.py and add-node-to-cluster.py scripts
#   for examples of how to use this class.
#
# Overview :
#   The MapR installer service is a simple web service
#   that allows the controlled deployment of a Mapr cluster.
#   The service can be accessed with REST requests to
#       1. set the proper values for the installation
#       2. walk through the installation process
#
#   This python class is designed to simplify those operations,
#   wrapping the authentication and formatting logic around the
#   REST requests into a simpler format.
#
# Prerequisites :
#   1. A running copy of the MapR Installer.
#       see deploy-installer.sh script, which installs the 
#       Installer and also adds the "requests" package to the 
#       local python directory (will be standard in future 
#       releases of the installer).
#   2. A set of nodes on which to deploy the software
#   

import os
import sys
import subprocess
import datetime
import time
import ssl
import requests,json
requests.packages.urllib3.disable_warnings()

import logging

__author__ = "MapR"
 

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
        self.eco_defaults = { 'drill' : '1.4', 'hbase' : '0.98', 'hive' : '1.2', 'pig' : '0.15' }
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
                if r.headers['Content-Type'] == 'application/json' :
                    dbgStr = json.dumps(r.json(),indent=4,sort_keys=True)
                else :
                    dbgStr = r.text
                self.logger.debug ("  rval: "+dbgStr)
                return r

    def swagger_patch(self, target, payload) :
        self.logger.debug ("MIDriver::swagger_patch(%s, %s)", target, payload)
        r = self.installer_session.patch(self.installer_url + target,
                auth = (self.mapr_user, self.mapr_password),
                headers = self.headers,
                verify = False,
                data = json.dumps(payload))
        if r.status_code != requests.codes.ok :
            self.logger.warn ("MIDriver::swagger_patch(%s, %s) returned bad status %d", target, payload, r.status_code)

    def swagger_post(self, target, payload) :
        self.logger.debug ("MIDriver::swagger_post(%s, %s)", target, payload)
        r = self.installer_session.post(self.installer_url + target,
                auth = (self.mapr_user, self.mapr_password),
                headers = self.headers,
                verify = False,
                data = json.dumps(payload))
        if r.status_code != requests.codes.ok :
            self.logger.warn ("MIDriver::swagger_post(%s, %s) returned bad status %d", target, payload, r.status_code)

    def config_get(self) :
        return self.swagger_get("/api/config")

    def config_patch(self, payload) :
        self.swagger_patch ("/api/config", payload)

    def groups_get(self,groupName) :
        payload = { 'label' : groupName}
        r = self.installer_session.get(self.installer_url + "/api/groups",
                auth = (self.mapr_user, self.mapr_password),
                headers = self.headers,
                params = payload, 
                verify = False)
        return r

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


        # Set up core services for the cluster.
        # Optional "storage-only" flag will preclude ALL Hadoop services
    def initializeCoreServicesList (self, mapr_version = None, storage_only = False ) :
        if mapr_version != None:
            self.mapr_version = mapr_version
        self.services = {}

            # MapR core stuff (forget MRv1 for now)
        self.services["mapr-core"] = { "enabled" : True, "version" : self.mapr_version }
        self.services["mapr-cldb"] = { "enabled" : True, "version" : self.mapr_version }
        self.services["mapr-fileserver"] = { "enabled" : True, "version" : self.mapr_version }
        self.services["mapr-webserver"] = { "enabled" : True, "version" : self.mapr_version }
        self.services["mapr-zookeeper"] = { "enabled" : True, "version" : self.mapr_version }

            # MapR YARN stuff (forget MRv1 for now)
        if storage_only == False :
            self.services["mapr-nodemanager"] = { "enabled" : True, "version" : self.mapr_version }
            self.services["mapr-resourcemanager"] = { "enabled" : True, "version" : self.mapr_version }
            self.services["mapr-historyserver"] = { "enabled" : True, "version" : self.mapr_version }

            # Always include NFS service
        self.services["mapr-nfs"] = { "enabled" : True, "version" : self.mapr_version }

            
            # The class defaults are generally for the most
            # recent MapR release, so we'll use this check to 
            # deal with the case where we need to "downgrade" 
            # ecosystem packages before we initialize the 
            # list in the Installer itself.
    def initializeEcoServicesList (self) :
        if self.mapr_version < '5.0.0' : 
            self.eco_defaults['hive'] = '0.13'
            self.eco_defaults['pig'] = '0.14'

            # Always include Kafka for MapR-Streams Support (5.x and higher)
        if self.mapr_version >= '5.1.0' : 
            self.eco_defaults['kafka'] = '0.9.0'

        ver = self.eco_defaults.get('hbase')
        if ver != None : 
            self.addMapRDBServices (ver)

        ver = self.eco_defaults.get('kafka')
        if ver != None : 
            self.addEcoServices ('kafka', ver)

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
            hive_version = self.eco_defaults.get('hive', "1.0")
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
            hive_version = self.eco_defaults.get('hive', "1.0")

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
            spark_version = self.eco_defaults.get('spark', "1.4.1")
        elif spark_version.lower() == "none" :
            if 'mapr-spark-client' in self.services :
                del self.services['mapr-spark-client']
            if 'mapr-spark-historyserver' in self.services :
                del self.services['mapr-spark-historyserver']
            return
        elif self.service_available ('spark', spark_version) == False : 
            spark_version = self.eco_defaults.get('spark', "1.4.1")

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

        payload = { 'cluster_admin_create' : True }
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
            # account to retrieve a trial license (as a temporary workaround)
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
        #       This is achieved by adding the nodes to 
        #       CLIENT and DATA groups
    def updateClusterConfig(self) :
        self.logger.debug ("MIDriver::updateClusterConfig")
        self.logger.debug ("  hosts:"+','.join(self.hosts))
            # webserver
        svc_target="/api/services/"+"mapr-webserver-"+self.mapr_version
        r = self.swagger_get (svc_target)
        wsHosts = list(r.json()['hosts'])
        if self.hosts[0] not in wsHosts :
            wsHosts.append (self.hosts[0])
            self.swagger_patch (svc_target, {"hosts" : wsHosts})

            # Option 1: bulk ... definitely quicker than 
            # loop approach below.
        r = self.groups_get('DATA')
        if r.json()['count'] == 1 :
            groupId = r.json()['resources'][0]['id']
            grp_target="/api/groups/"+str(groupId)
            self.swagger_patch (grp_target, {"hosts" : self.hosts})

        r = self.groups_get('CLIENT')
        if r.json()['count'] == 1 :
            groupId = r.json()['resources'][0]['id']
            grp_target="/api/groups/"+str(groupId)
            self.swagger_patch (grp_target, {"hosts" : self.hosts})

            # Option 2: 1-at-a-time
#        for h in self.hosts :
#            self.addNodeToGroup(h, 'DATA')
#            self.addNodeToGroup(h, 'CLIENT')


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


        # Check the cluster config.   Optional "hosts" argument
        # is used when adding hosts to an existing cluster, since
        # we don't need to validate the nodes we've already installed.
    def checkClusterConfig(self, hosts=None) :
        self.logger.debug ("MIDriver::checkClusterConfig()")
        if self.hosts == None :
            logger.critical ("No hosts specified")
            return (False)

        if self.disks == None  or  len(self.disks) <= 0 :
            logger.critical ("No disks specified")
            return (False)

            # Handle case were earlier invocation has
            # left us in INSTALL_ERROR.  There's no need 
            # for "CHECKING" in that case.
        if self.current_state != "INSTALL_ERROR" :
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

            # If no services are specified, we know
            # we are just running "addNode", which
            # does not require this extra step.
        if len(self.services) > 0 :
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

    def doUninstall(self) :
        self.logger.debug ("MIDriver::doUninstall()")

        r = self.process_get()
        self.current_state  = r.json()['state']

		# TBD ... handle "correct" states a bit better
        if self.current_state != "UNINSTALLING" :
            payload = { 'state' : 'UNINSTALLING' }
            self.process_patch (payload)

        rc = self.waitForProcessState( 'UNINSTALLED' , 5400, 20)
        if rc != True  and  self.current_state != 'INIT' :
            return (rc)

        return (True)


        # TBD : handle "group doesn't exist" error more completely
    def addNodeToGroup(self, newNode, targetGroup) :
        self.logger.debug ("MIDriver::addNodeToGroup("+newNode+","+targetGroup+")")
        r = self.groups_get(targetGroup)
        if r.json()['count'] < 1 :
            return (False)

        groupId = r.json()['resources'][0]['id']
        grp_target="/api/groups/"+str(groupId)

        r = self.swagger_get(grp_target)
        groupHosts = r.json()['hosts']
        self.logger.debug ("   "+targetGroup+" hosts: " + ','.join(groupHosts))

        if newNode in groupHosts :
            self.logger.debug ("   "+newNode+" is already in cluster group "+targetGroup)
        else :
            groupHosts.append (newNode)
            self.swagger_patch (grp_target, {"hosts" : groupHosts})
        

        # Add a new node to the cluster, into a particular group
        # Assume it's a simple data node (so it will be in the
        # "DEFAULT" group as well as the "DATA" group).
        #
        # TBD : should skip the 'INSTALLING' step if the node
        # already exists in cluster config and all target groups.
    def addNode(self, newNode, targetGroup='DATA') :
        self.logger.debug ("MIDriver::addNode("+newNode+")")

        if (newNode == None) :
            return (False)

        r = self.config_get()
        clusterHosts = r.json()['hosts']
        self.logger.debug ("   current hosts: " + ','.join(clusterHosts))

        if newNode in clusterHosts :
            self.logger.debug ("   "+newNode+" is already in cluster config")
        else :
            clusterHosts.append (newNode)
            self.logger.debug ("   updated host list: " + ','.join(clusterHosts))
            payload = { 'hosts' : clusterHosts } 
            self.config_patch(payload)

            payload = { 'id' : newNode } 
            self.swagger_post ("/api/hosts", payload)

                # NOTE: At this point, we need to "CHECK" and
                # "PROVISION" the configuration, so that our
                # addNodeToGroup operations will work below
                #
                # Transfer necessary values to this instance
                # of the driver object so that it will do the 
                # right thing.
                #   TBD: should probably add a "Retrieve Current Config"
                #   option so that we can manage this better.
        self.hosts = list(clusterHosts)
        self.disks = list(r.json()['disks'])
        self.checkClusterConfig(list(newNode))

        self.addNodeToGroup (newNode, targetGroup)
        if (targetGroup == 'DATA') :
            self.addNodeToGroup (newNode, 'CLIENT')
            
        self.doInstall()

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

        # This is designed to print the overall installation
        # status as well as the status across all the hosts
        # (that have the SAME status as the overall version
        # or an ERROR state)
    def printProcessStatus(self) :
        r = self.process_get ()
        if r.status_code == requests.codes.ok :
            curStatus = r.json()['status']
            self.logger.info ("Installer status : "+curStatus)
        else :
            return

        for h in self.hosts :
            h_target="/api/hosts/?id="+h
            r = self.swagger_get (h_target)
            if r.status_code == requests.codes.ok :
                hState = r.json()['resources'][0]['state']
                hStatus = r.json()['resources'][0]['status']
                if hState == self.current_state :
                    self.logger.info ("Host ("+h+") status : "+hStatus)
                elif hState[-5:] == "ERROR" :
                    self.logger.info ("Host ("+h+") status : "+hStatus)

        self.logger.info ("Check "+self.installer_url+"/api/process/log for additional details")

        # TBD : be smarter about formatting the log ... it's raw text
        # and often VERY confusing
    def printProcessLog(self) :
        r = self.swagger_get ("/api/process/log")
        if r.status_code == requests.codes.ok :
            self.logger.info ("Process Log:"+r.text)

    def printSuccessUrl(self) :
        self.logger.info ("MapR Installer Service available at "+self.installer_url+"/#/complete") 
        sys.stdout.flush()

