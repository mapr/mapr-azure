#!/bin/bash
#
# Removes password based SSH on all servers
#
# Usage :
#	$0 <admin_user> <auth_method>
#
# Examples
#	$0 azadmin < password | sshPublicKey >
#
# Requirements :
#	sshpass utility; if run as root user, will attempt installation
#	key-based authentication for admin_user between the nodes is configured
#		(this is done with gendist-sshkey.sh in installer-wrapper.sh)
#	/tmp/lock.sh script created properly (part of gen-cluster-lock.sh)
#	
# Return codes
#	0 : Success
#	1 : invalid arguments
#	2 : sshpass utility not found (or uninstallable)
#

CF_HOSTS_FILE=/tmp/maprhosts
LOCK_SCRIPT=/tmp/lock.sh
THIS_USER=`id -un`

# Get methos from the command line.
USER=${1:-azadmin}
AUTH_METHOD=${2:-password}

[ $AUTH_METHOD = "password" ] && exit 0

which sshpass &> /dev/null
if [ $? -ne 0 ] ; then
	[ $THIS_USER != "root" ] && exit 2
	yum install -y sshpass
	[ $? -ne 0 ] && exit 2
fi

SUDO="su ${USER}"
[ $USER = $THIS_USER ] && SUDO=""


# Run the lock script on all the nodes
#	NOTE: the EXACT invocation of the lock script must match the 
#	sudoers entry added in gen-create-lock.sh
#
MY_SSH_OPTS="-oStrictHostKeyChecking=no -oPasswordAuthentication=no"
for h in `awk '{print $1}' $CF_HOSTS_FILE` ; do
	if [ -n "${SUDO}" ] ; then
		$SUDO -c "ssh $MY_SSH_OPTS ${USER}@${h} sudo -u root /bin/bash ${LOCK_SCRIPT}"
	else
		ssh $MY_SSH_OPTS ${USER}@${h} sudo -u root /bin/bash ${LOCK_SCRIPT}
	fi

done

exit 0
