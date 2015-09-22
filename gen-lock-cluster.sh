#!/bin/bash
#
# Removes password based SSH on all servers
#
# Usage :
#	$0 <ssh_user> <auth_method>
#
# Examples
#	$0 mapraz SSHKey
#
#
# Requirements :
#	sshpass utility; if run as root user, will install the tool
#	
# Return codes
#	1 : invalid arguments
#	2 : sshpass utility not found (or uninstallable)
#

CF_HOSTS_FILE=/tmp/maprhosts
LOCK_SCRIPT=/tmp/lock.sh
THIS_HOST=`/bin/hostname`
THIS_USER=`id -un`

# Get methos from the command line.
METHOD=${2:-}
USER=${1:-azadmin}

[ $METHOD = "Password" ] && exit 0

which sshpass &> /dev/null
if [ $? -ne 0 ] ; then
	[ $THIS_USER != "root" ] && exit 2
	yum install -y sshpass
	[ $? -ne 0 ] && exit 2
fi

SUDO="su ${USER}"
[ $USER = $THIS_USER ] && SUDO=""


# Run the lock script on all the nodes
#
MY_SSH_OPTS="-o StrictHostKeyChecking=no -o PasswordAuthentication=no"
for h in `awk '{print $1}' $CF_HOSTS_FILE` ; do
	if [ -n "${SUDO}" ] ; then
		$SUDO -c "ssh $MY_SSH_OPTS ${USER}@${h} sudo -u root /usr/bin/bash ${LOCK_SCRIPT}"
	else
		ssh $MY_SSH_OPTS ${USER}@${h} sudo -u root /usr/bin/bash ${LOCK_SCRIPT}
	fi

done

