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
#	.ssh/config is overwritten on all nodes
#	.ssh/authorized_keys is updated on all nodes
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

# We'll use the user's home directory a lot (and '~' may not evaluate
# correctly in the following commands) , so let's set an env variable
USER_DIR=`eval "echo ~${USER}"`

if [ -n "${SUDO}" ] ; then
	$SUDO -c "ssh-keygen -q -t rsa -P '' -f ${USER_DIR}/${KEYFILE}"
	$SUDO -c "cat << sscEOF >> ${USER_DIR}/.ssh/config 
StrictHostKeyChecking no

IdentityFile  ~/${KEYFILE} 
sscEOF"
	$SUDO -c "chmod 600 ${USER_DIR}/.ssh/config"
else
	ssh-keygen -q -t rsa -P '' -f ${USER_DIR}/${KEYFILE}
	cat << scEOF >> ${USER_DIR}/.ssh/config
IdentityFile  ~/${KEYFILE}
scEOF
	chmod 600 ${USER_DIR}/.ssh/config
fi

[ ! -r $CF_HOSTS_FILE ] && exit 0

# Copy the key to all nodes ... so that everyone can have equal access
#
MY_SSH_OPTS="-oStrictHostKeyChecking=no -oPasswordAuthentication=yes"
SSH_KEY="`cat ${USER_DIR}/${KEYFILE}.pub`"
for h in `awk '{print $1}' $CF_HOSTS_FILE` ; do
#		Can't use ssh-copy-id through the SUDO and sshpass wrappers.
#		Seed the authorized_keys file on the remote system "by hand"
#	$SUDO -c "SSHPASS=$PASSWD sshpass -e /usr/bin/ssh-copy-id $MY_SSH_OPTS ${USER}@${h}"
	SSHPASS=$PASSWD sshpass -e ssh $MY_SSH_OPTS ${USER}@${h} mkdir .ssh
	SSHPASS=$PASSWD sshpass -e ssh $MY_SSH_OPTS ${USER}@${h} "echo \"$SSH_KEY\" >> .ssh/authorized_keys"
	SSHPASS=$PASSWD sshpass -e ssh $MY_SSH_OPTS ${USER}@${h} "chmod go-rwx .ssh .ssh/authorized_keys"
	scp -i ${USER_DIR}/${KEYFILE} ${USER_DIR}/${KEYFILE}* ${USER}@${h}:.ssh
	scp -i ${USER_DIR}/${KEYFILE} ${USER_DIR}/.ssh/config  ${USER}@${h}:.ssh

done

