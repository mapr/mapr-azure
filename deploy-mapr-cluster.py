#!/usr/bin/env python
#
#   NOTE: Requires Python 2.7 
#
# Usage
#
# Important details about defaults
#   There are multiple levels of attribute defaults in this
#   script.  The MIDriver class __could__ be leveraged elsewhere, 
#   so it has a simple set of defaults:
#       installer_url = https://localhost:9443
#       mapr_version : 4.1.0
#       mapr_edition = 'M3'
#       mapr_user = mapr
#       mapr_password = mapr
#       cluster = 'my.cluster.com'
#
#   The command line parsing also has some defaults ... which 
#   help when setting up the driver object in this temp wrapper.
#       installer_url = https://localhost:9443
#       mapr_version : 4.1.0
#       mapr_edition = 'M3'
#       mapr_user = mapr
#       mapr_password = MapR
#       cluster = 'MyCluster'
#       ssh-user = 'ec2-user'
#       ssh-keyfile = "~/.ssh/id_launch


import argparse
import os
import subprocess
import datetime
import time
import ssl
import requests,json
requests.packages.urllib3.disable_warnings()

__author__ = "MapR"


# Simple class to drive the MapR Installer service
class MIDriver:
    def __init__(self, url="https://localhost:9443", user="mapr", passwd="mapr") :
            # All our REST traffic to the Installer uses these headers
        self.headers = { 'Content-Type' : 'application/json' } 
        self.installer_url = url
        self.mapr_user = user
        self.mapr_password = passwd
        self.cluster = 'my.cluster.com'
        self.mapr_version = '4.1.0'
        self.mapr_edition = 'M3'
        self.disks = []
        self.hosts = []
        self.services = {}
        self.ssh_user = None
        self.ssh_password = None
        self.ssh_key = None
        self.portal_user = None
        self.portal_password = None

        # TBD : Be smarter
        #   check for 0-lenghth list.
    def setClusterName(self, newName) :
        if newName != None :
            self.cluster = newName

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

    def setHosts(self, newHosts) :
        if newHosts != None :
            self.hosts = newHosts

    def setDisks(self, newDisks) :
        if newDisks != None :
            self.disks = newDisks

    def config_get(self) :
        r = requests.get(self.installer_url + "/api/config",
                auth = (self.mapr_user, self.mapr_password),
                headers = self.headers,
                verify = False)
        return r

    def config_patch(self, payload) :
        requests.patch(self.installer_url + "/api/config",
                auth = (self.mapr_user, self.mapr_password),
                headers = self.headers,
                verify = False,
                data = json.dumps(payload))

    def process_get(self) :
        r = requests.get(self.installer_url + "/api/process",
                auth = (self.mapr_user, self.mapr_password),
                headers = self.headers,
                verify = False)
        return r

    def process_patch(self,payload) :
        requests.patch(self.installer_url + "/api/process",
                auth = (self.mapr_user, self.mapr_password),
                headers = self.headers,
                verify = False,
                data = json.dumps(payload))

    def initializeServicesList (self, mapr_version = None) :
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

        # Always include NFS; Installer 
        self.services["mapr-nfs"] = { "enabled" : True, "version" : self.mapr_version }

        # Hive (with only local MySQL supported for now)
    def addHiveServices (self, hive_version = "0.13", hive_user = None, hive_password = None, hive_db = "local") :
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
        self.services["mapr-metastore"] = { "enabled" : True, "database" : HIVE_DATABASE, "version" : hive_version }
    

        # Hive (with only local MySQL supported for now)
    def addMapRDBServices (self, hbase_version = "0.98") :
        self.services["mapr-hbase"] = { "enabled" : True, "version" : hbase_version }
        self.services["mapr-hbasethrift"] = { "enabled" : True, "version" : hbase_version }
        self.services["mapr-libhbase"] = { "enabled" : True, "version" : hbase_version }

    def addSparkServices (self, spark_version = "1.2.1") :
        self.services["mapr-spark-client"] = { "enabled" : True, "version" : spark_version }
        self.services["mapr-spark-historyserver"] = { "enabled" : True, "version" : spark_version }

    def addDrillServices (self, drill_version = "1.0.0") :
        self.services["mapr-drill"] = { "enabled" : True, "version" : drill_version}



    def configureClusterDeployment(self) :
        payload = { 'cluster_admin_password' : self.mapr_password } 
        self.config_patch(payload)

        payload = { 'cluster_name' : self.cluster } 
        self.config_patch(payload)

        payload = { 'disks' : self.disks } 
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

        # For automated license installation, we'll use an internal
        # account (as a temporary workaround)
        payload = { 'license_type' : self.mapr_edition } 
        self.config_patch(payload)
        
        if self.portal_user != None   and  self.portal_password != None :
            payload = { 'mapr_name' : self.portal_user, 'mapr_password' : self.portal_password } 
            self.config_patch(payload)

        # Last, but not least, specify the services
        payload = { 'services' : self.services } 
        self.config_patch(payload)

            # Print out the message config for sanity 
            # (long term, we'll drop this)
        r = self.config_get()
        print json.dumps(r.json(),indent=4,sort_keys=True)

        rc = self.waitForProcessState( 'INIT' )


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
                print ("%s  : Waiting for %s (current state %s)" % (timeHdr, tgtState, curState) )
                maxWait -= waitInterval
                time.sleep(waitInterval)
            else :
                maxWait = 0
                break

        print ( "Installer state %s" % (curState) )
        return (maxWait > 0) 


    def doInstall(self) :
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

        payload = { 'state' : 'INSTALLING' } 
        self.process_patch (payload)
        rc = self.waitForProcessState( 'INSTALLED' , 3600, 20)
        if rc != True :
            return (rc)

        return (True)



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

    parser.add_argument("-q","--quiet", action="store_true",
        help="Execute silently, without prompting user.")
    parser.add_argument("--cluster", default="MyCluster",
        help="Cluster name")
    parser.add_argument("--mapr-version", default="4.1.0",
        help="MapR Software Version")
    parser.add_argument("--mapr-edition", default="M3",
        help="MapR License Edition (M3, M5, or M7)")
    parser.add_argument("--mapr-user", default="mapr",
        help="MapR admin user")
    parser.add_argument("--mapr-password", default="MapR",
        help="password for MapR admin user")
    parser.add_argument("--installer-url", default="https://localhost:9443",
        help="URI for MapR installer service")
    parser.add_argument("--ssh-user", default="ec2-user",
        help="ssh user for system access")
    parser.add_argument("--ssh-keyfile", default="~/.ssh/id_launch",
        help="ssh private key file")
    parser.add_argument("--portal-user",
        help="Registered user for mapr.com portal")
    parser.add_argument("--portal-password",
        help="Password for portal user")
    parser.add_argument("--disks",
        help="Comma-separate list of disks for MapR-FS on cluster nodes")
    parser.add_argument("--hosts",
        help="Comma-separate list of hosts on which to deploy MapR")
    parser.add_argument("--hosts-file",
        help="File containing hosts (one host per line)")

    args = parser.parse_args()
    return (args)


# Read in hosts file.  If file doesn't exist, simply return
# empty list (we should do better here).
# NOTE:
#   This is of the form it is to handle the legacy condition where
#   the list of hosts is generated by the Amazon Cloud Formation 
#   template (and the host name is accompanied by other info for
#   assisting in system configuration)
def genHostsList (hostsFile) :
    hosts = [] 

    if not os.path.isfile(hostsFile) :
        return (hosts)

        # Careful with Popen here.   The "$1" in the awk command
        # needs to make it all the way through the shell invocation,
        # and that was a bit problematic.
    proc = subprocess.Popen('/usr/bin/env awk "{print \$1}" '+hostsFile, shell=True, stdout=subprocess.PIPE)

    while ( True ) :
        h = proc.stdout.readline() 
        if h == '' :
            break
        else :
            h = h.rstrip()

        if ( len (h) > 0 ) :
            hosts.append (h)

    return (hosts)


# Expand the arguments that need expanding just in case.
# Actual validation of will be done in the MIDriver class
# (since we can set some rational defaults there)
def checkArgs (argList) :
    if argList.hosts == None :
        if argList.hosts_file != None :
            argList.hosts = genHostsList (argList.hosts_file)
    else :
        newHosts = argList.hosts.split(",")
        argList.hosts = newHosts

    if argList.disks != None :
        argList.disks = argList.disks.split(",")

        # Extract key file (if possible)
    if argList.ssh_keyfile != None : 
        with open (argList.ssh_keyfile, "r") as keyfile:
            ssh_key = keyfile.read()
        argList.ssh_key = ssh_key

        # Use our public credentials for now, if nothing is set
    if argList.portal_user == None : 
        argList.portal_user = "maprse-bd@maprtech.com"
        argList.portal_password = "BD4dev"

    return argList


    
# Temporary logic.  We should get much smarter here about how
# to decide which packages we want
def genServicesList (args) :
    svcs = {}

        # MapR core YARN stuff (forget MRv1 for now)
    svcs["mapr-core"] = { "enabled" : True, "version" : args["mapr_version"] }
    svcs["mapr-cldb"] = { "enabled" : True, "version" : args["mapr_version"] }
    svcs["mapr-fileserver"] = { "enabled" : True, "version" : args["mapr_version"] }
    svcs["mapr-nodemanager"] = { "enabled" : True, "version" : args["mapr_version"] }
    svcs["mapr-resourcemanager"] = { "enabled" : True, "version" : args["mapr_version"] }
    svcs["mapr-historyserver"] = { "enabled" : True, "version" : args["mapr_version"] }
    svcs["mapr-webserver"] = { "enabled" : True, "version" : args["mapr_version"] }
    svcs["mapr-zookeeper"] = { "enabled" : True, "version" : args["mapr_version"] }

        # Always include NFS
    svcs["mapr-nfs"] = { "enabled" : True, "version" : args["mapr_version"] }

        # HBase and related libraries
    svcs["mapr-hbase"] = { "enabled" : True, "version" : "0.98" }
    svcs["mapr-hbasethrift"] = { "enabled" : True, "version" : "0.98" }
    svcs["mapr-libhbase"] = { "enabled" : True, "version" : "0.98" }
    
        # Hive (with local MySQL for now)
    svcs["mapr-mysql"] = { "enabled" : True }
    HIVE_DATABASE = { "type" : "MYSQL", "create" : True, "name" : "hive_013", "user" : "hive", "password" : MAPR_PASSWD }

    svcs["mapr-hive-client"] = { "enabled" : True, "version" : "0.13" }
    svcs["mapr-hiveserver2"] = { "enabled" : True, "version" : "0.13" }
    svcs["mapr-metastore"] = { "enabled" : True, "database" : HIVE_DATABASE, "version" : "0.13" }
    
        # Spark
    svcs["mapr-spark-client"] = { "enabled" : True, "version" : "1.2.1" }
    svcs["mapr-spark-historyserver"] = { "enabled" : True, "version" : "1.2.1" }

        # Drill
    svcs["mapr-drill"] = { "enabled" : True, "version" : "1.0.0" }

    return svcs



# Parse our command line, do some minimal error checking
# and variable expansion
myArgs = gatherArgs()
checkedArgs = checkArgs (myArgs)

    # Convert Namespace to a Dictionary (to get rid of our
    # "null" values" and allow iteration).
# argDict = vars(checkedArgs)
# print json.dumps(argDict,indent=4,sort_keys=True)


# TBD  Confirm settings with user here before proceeding

# TBD Change design to throw exception if the installer is not found
driver = MIDriver (checkedArgs.installer_url, checkedArgs.mapr_user, checkedArgs.mapr_password)


# TBD Much better error handling ... including dump of the complete
# cluster configuration is going to be AFTER the provisioning step
#
driver.setClusterName (checkedArgs.cluster)
driver.setSshCredentials (
    getattr(checkedArgs,'ssh_user', None), 
    getattr(checkedArgs,'ssh_key', None), 
    getattr(checkedArgs,'ssh_password', None)) 
driver.setPortalCredentials (
    getattr(checkedArgs,'portal_user', None), 
    getattr(checkedArgs,'portal_password', None)) 
driver.setHosts (checkedArgs.hosts)
driver.setDisks (checkedArgs.disks)

# Set up services ... could be much smarter here 
#   (especially about the versioning for each service).
driver.initializeServicesList (checkedArgs.mapr_version)
driver.addMapRDBServices ()
driver.addSparkServices ()
driver.addDrillServices ()
driver.addHiveServices ()

operationOK = driver.configureClusterDeployment()
if operationOK == True :
    cont = query_yes_no ("Continue with installation ?", "yes")
    if cont != True :
        exit (0)

operationOK = driver.doInstall()
