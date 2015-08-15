#!/bin/bash
#
# Generate an ssh key for a particular user and distribute it
# to the hosts in the MapR cluster (identified by CF_HOSTS_FILE)
#
# Usage :
#	$0 <user> <password> [ ssh-key-name ]
#
# Examples
#	$0 azadmin azpasswd id_launch
#
# Side Effects
#	Generated key overwrites pre-existing keys of the same name (on
#	local and remote nodes)
#	
#	.ssh/config and .ssh/known_hosts are overwritten on all nodes
#
# Requirements :
#	sshpass utility; if run as root user, will install the tool
#	
# Return codes
#	1 : invalid arguments
#	2 : sshpass utility not found (or uninstallable)
#	3 : ssh-keygen failed
#

CF_HOSTS_FILE=/tmp/maprhosts
THIS_HOST=`/bin/hostname`
THIS_USER=`id -un`

# Get user and user's password from the command line.
# ssh-copy-id requires keys to be of the form "id*", so we enforce
# that here.
USER=${1:-}
PASSWD=${2:-}
if [ -n "${3:-}"  -a  "${3#id}" != "${3}" ] ; then
	KEYFILE=".ssh/${3}"
else
	KEYFILE=".ssh/id_launch"
fi

[ -z "${USER:-}" -o  -z "${PASSWD:-}" ] && exit 1

which sshpass &> /dev/null
if [ $? -ne 0 ] ; then
	[ $THIS_USER != "root" ] && exit 2
	yum install -y sshpass
	[ $? -ne 0 ] && exit 2
fi

SUDO="su ${USER}"
[ $USER = $THIS_USER ] && SUDO=""		# no need for su in this case

if [ -n "${SUDO}" ] ; then
	$SUDO -c "ssh-keygen -q -t rsa -P '' -f ~${USER}/${KEYFILE}"
	$SUDO -c "cat << sscEOF >> ~${USER}/.ssh/config 
IdentityFile  ~/${KEYFILE} 
sscEOF"
	$SUDO -c "chmod 600 ~${USER}/.ssh/config"
else
	ssh-keygen -q -t rsa -P '' -f ~${USER}/${KEYFILE}
	cat << scEOF >> ~/.ssh/config
IdentityFile  ~/${KEYFILE}
scEOF
	chmod 600 ~/.ssh/config
fi

[ $? -ne 0 ] && exit 3

[ ! -r $CF_HOSTS_FILE ] && exit 0

# Copy the key to all nodes ... so that everyone can have equal access
#
MY_SSH_OPTS="-o StrictHostKeyChecking=no -o PasswordAuthentication=yes"
for h in `awk '{print $1}' $CF_HOSTS_FILE` ; do
	if [ -n "${SUDO}" ] ; then
		$SUDO -c "SSHPASS=$PASSWD sshpass -e ssh-copy-id $MY_SSH_OPTS ${USER}@${h}"
		$SUDO -c "scp ~${USER}/${KEYFILE}* ${USER}@${h}:.ssh"
		$SUDO -c "scp ~${USER}/.ssh/config  ${USER}@${h}:.ssh"
	else
		SSHPASS=$PASSWD sshpass -e ssh-copy-id $MY_SSH_OPTS ${USER}@${h}
		scp ~${USER}/${KEYFILE}* ${USER}@${h}:.ssh
		scp ~${USER}/.ssh/config  ${USER}@${h}:.ssh
	fi

done

