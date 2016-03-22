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
#   so it has a simple set of defaults (see MIDriver.py):
#       installer_url = https://localhost:9443
#       mapr_version : 5.0.0
#       mapr_edition = 'M3'
#       mapr_user = mapr
#       mapr_password = mapr
#       cluster = 'my.cluster.com'
#       ecosystem defaults
#           { 'drill' : '1.4', 'hbase' : '0.98', 'hive' : '1.2', 'pig' : '0.15' }
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
#
# TBD
#   Add logic to support "--eco-verison <product>=latest" ... for latest 
#   supported version.


import os
import sys
import subprocess
import argparse
import datetime
import json
import time
import ssl

import logging
import logging.config 

from MIDriver import MIDriver

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
              'filename': '/tmp/mid.log',
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


# Variables we should be grabbing based on customer input or
# deployment infrastructure
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
    parser.add_argument("--ignore-warnings", default=False, action="store_true",
        help="Proceed with operation even on WARN state")
    parser.add_argument("-l", "--log-level", default="INFO",
        help="Relative logging level (DEBUG,INFO,WARN,ERROR,CRITICAL")
    parser.add_argument("--log-file", 
        help="log file for this execution")
    parser.add_argument("--cluster", default="MyCluster",
        help="Cluster name")
    parser.add_argument("--mapr-version", default="4.1.0",
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



#  logging.basicConfig(filename="/tmp/mid.log", level=logging.INFO, filemode="w")

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
for svc in [ 'pig', 'drill', 'hue', 'oozie' ] :
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
    driver.printProcessStatus()
    logger.error ( "Failed to initialized installer services; aborting" )
    exit (1)

operationOK = driver.checkClusterConfig()
if operationOK == True :
    if checkedArgs.yes == False :
        cont = query_yes_no ("Configuration validated; continue with INSTALL ?", "yes")
        if cont != True :
            exit (0)
else :
    state=driver.current_state
    if state[-4:] == "WARN"  and  checkedArgs.ignore_warnings == True :
        if checkedArgs.yes == False :
            cont = query_yes_no ("Configuration validated (with WARNINGS); continue with INSTALL ?", "yes")
            if cont != True :
                exit (0)
    else :
        driver.printProcessStatus()
        logger.error ( "Failed to validate configuration; aborting" )
        exit (2)

operationOK = driver.doInstall()
if operationOK == False :
    driver.printProcessStatus()
    logger.error ( "Failed to complete cluster installation; aborting" )
    exit (3)

if checkedArgs.quiet == False :
    logger.info ( "" )
    driver.printSuccessUrl()
    driver.printMCS()

logger.info('deploy-mapr-cluster.py completed')
exit (0)
