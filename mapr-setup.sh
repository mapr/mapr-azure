#!/bin/bash
#
#SOUSAGE
#
#NAME
#  CMD - © MapR Technologies, Inc., All Rights Reserved
#
#DESCRIPTION
#
#  MapR distribution initialization and setup
#
#SYNOPSIS
#  CMD [options] [install|reload|remove|update]
#
#OPTIONS
#
#  -a|--archive <file>       Specify the full path to the complete MapR
#                            installation archive file (mapr-all.*)
#
#  -f|--force                Force re-prompts and do not test for upgrade
#
#  -h|--help                 Display this help message
#
#  -i|--install definitions-pkg installer-pkg
#                            Specify the full path to MapR installer and
#                            service definition packages
#
#  -p|--port                 Set installer HTTPS port (9443)
#
#  -r|--repo
#                            Specify the top repository URL for MapR installer,
#                            core and ecosystem package directories
#
#  -u|--urls <installer-url> <core-url> <eco-url>
#                            Specify the individual repository URLs for MapR
#                            installer, core and ecosystem package directories
#
#  -y|--yes                  Do not prompt and accept all default values
#
#EOUSAGE

CMD=${0##*/}
VERSION=1.0

ECHOE="echo -e"
[ "$(echo -e)" = "-e" ] && ECHOE="echo"
DOMAIN=$(hostname -d 2>/dev/null)
ID=$(id -u)
PAGER=${PAGER:-more}
USER=$(id -n -u)
INSTALLER=$(cd $(dirname $0) 2>/dev/null && echo $(pwd)/$(basename $0))

MAPR_ENVIRONMENT=
MAPR_UID=${MAPR_UID:-5000}
MAPR_GID=${MAPR_GID:-5000}
MAPR_USER=${MAPR_USER:-mapr}
MAPR_USER_CREATE=${MAPR_USER_CREATE:-false}
MAPR_GROUP=${MAPR_GROUP:-mapr}
MAPR_GROUP_CREATE=${MAPR_GROUP_CREATE:-false}
MAPR_HOME=${MAPR_HOME:-/opt/mapr}
MAPR_PORT=${MAPR_PORT:-9443}
MAPR_DATA_DIR=${MAPR_DATA_DIR:-${MAPR_HOME}/installer/data}
MAPR_PROPERTIES_FILE="$MAPR_DATA_DIR/properties.json"
if [ -z "$MAPR_PKG_URL" ]; then
    MAPR_PKG_URL=http://package.mapr.com/releases
    [ "$DOMAIN" = "perf.lab" -o "$DOMAIN" = "qa.lab" -o "$DOMAIN" = "scale.lab" ] && MAPR_PKG_URL=http://package.qa.lab/releases
fi

# internal installer packages under [apt|yum].qa.lab/installer-package-ui1.0
MAPR_CORE_URL=${MAPR_CORE_URL:-$MAPR_PKG_URL}
MAPR_ECO_URL=${MAPR_ECO_URL:-$MAPR_PKG_URL}
MAPR_INSTALLER_URL=${MAPR_INSTALLER_URL:-$MAPR_PKG_URL/installer}
MAPR_INSTALLER_PACKAGES=
MAPR_ARCHIVE_DEB=${MAPR_ARCHIVE_DEB:-mapr-latest-*.deb.tar.gz}
MAPR_ARCHIVE_RPM=${MAPR_ARCHIVE_RPM:-mapr-latest-*.rpm.tar.gz}

DEPENDENCY_DEB="python-pycurl openssh-client libssl1.0.0 sshpass sudo wget"
DEPENDENCY_RPM="nss python-pycurl openssh-clients openssh-server openssl sshpass sudo wget which"
DEPENDENCY_SUSE="libopenssl1_0_0 sudo wget which" # python[py]curl

HTTPD_DEB=${HTTPD_DEB:-apache2}
HTTPD_RPM=${HTTPD_RPM:-httpd}
HTTPD_REPO_DEB=${HTTPD_REPO_DEB:-/var/www/html/mapr}
HTTPD_REPO_RPM=${HTTPD_REPO_RPM:-/var/www/html/mapr}

OPENJDK_DEB=${OPENJDK_DEB:-openjdk-7-jdk}
OPENJDK_RPM=${OPENJDK_RPM:-java-1.8.0-openjdk}
OPENJDK_SUSE=${OPENJDK_SUSE:-java-1_8_0-openjdk-devel}

#
# return Codes
#
NO=0
YES=1
INFO=0
WARN=-1
ERROR=1

if hostname -I > /dev/null 2>&1; then
    HOSTNAME=$(hostname -I | cut -d' ' -f1)
elif which ip > /dev/null 2>&1 && ip addr show > /dev/null 2>&1 ; then
    HOSTNAME=$(ip addr show | grep inet | grep -v 'scope host' | head -1 | sed -e 's/^[^0-9]*//; s/\(\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}\).*/\1/')
elif [ $(uname -s) = "Darwin" ]; then
    HOSTNAME=$(ipconfig getifaddr en0)
    [ -z "$HOSTNAME" ] && HOSTNAME=$(ipconfig getifaddr en1)
else
    HOSTNAME=$(hostname 2>/dev/null)
fi
HOSTNAME_INTERNAL=$HOSTNAME
ISUPDATE=$NO 
MAX_LENGTH=50
PROMPT_FORCE=$NO
PROMPT_SILENT=$NO
TEST_CONNECT=$YES

unset MAPR_ARCHIVE
unset MAPR_DEF_VERSION
unset MAPR_SERVER_VERSION
unset OS

##
## functions
##

usage() {
    code=${1-1}
    if [ $code -ne 0 ]; then
        tput bold
        formatMsg "\nERROR: invalid command-line arguments"
        tput sgr0
    fi
    head -$MAX_LENGTH $INSTALLER | \
        sed -e '1,/^#SOUSAGE/d' -e '/^#EOUSAGE/,$d' \
            -e 's/^\#//'        -e "s?CMD?$CMD?"    | $PAGER
    exit $code
}

catchTrap() {
    messenger $INFO ""
}


# Output an error, warning or regular message
messenger() {
    case $1 in
    $ERROR)
        tput bold
        formatMsg "\nERROR: $2"
        tput sgr0
        [ "$MAPR_USER_CREATE" = "true" ] && userdel $MAPR_USER > /dev/null 2>&1
        [ "$MAPR_GROUP_CREATE" = "true" ] && groupdel $MAPR_GROUP > /dev/null 2>&1
        exit $ERROR
        ;;
    $WARN)
        tput bold
        formatMsg "\nWARNING: $2"
        tput sgr0
        sleep 3
        ;;
    $INFO)
        formatMsg "$2"
        ;;
    *)
        formatMsg "$1"
        ;;
    esac
}

prompt() {
    QUERY=$1
    DEFAULT=${2:-""}
    shift 2
    if [ $PROMPT_SILENT = $YES ]; then
        if [ -z "$DEFAULT" ]; then
            messenger $ERROR "no default value available"
        else
            formatMsg "$QUERY: $DEFAULT\n" ""
            ANSWER=$DEFAULT
	    return
        fi
    fi
    unset ANSWER
    while [ -z "$ANSWER" ]; do
        if [ -z "$DEFAULT" ]; then
            formatMsg "$QUERY:" ""
        else
            formatMsg "$QUERY [$DEFAULT]:" ""
        fi
        if [ "$1" = "-s" -a -z "$BASH" ]; then
            trap 'stty echo' EXIT
            stty -echo
            read ANSWER
            stty echo
            trap - EXIT
        else
            read $* ANSWER
        fi
        if [ "$ANSWER" = "q!" ]; then
            exit 0
        elif [ -z "$ANSWER" ] && [ -n "$DEFAULT" ]; then
            ANSWER=$DEFAULT
        fi
        [ "$1" = "-s" ] && echo
    done
}

centerMsg() {
    width=$(tput cols)
    $ECHOE "$1" | awk '{ spaces = ('$width' - length) / 2
      while (spaces-- >= 1) printf (" ")
      print
    }'
}


# Print each word according to the screen size
formatMsg() {
    WORDS=$1
    LENGTH=0
    width=$(tput cols)
    for WORD in $WORDS; do
        LENGTH=$(($LENGTH + ${#WORD} + 1))
        if [ $LENGTH -gt $width ]; then
            $ECHOE "\n$WORD \c" 
            LENGTH=$((${#WORD} + 1))
        else
            $ECHOE "$WORD \c" 
        fi
    done
    if [ $# -eq 1 ]; then
        $ECHOE "\n" 
    fi
}

prologue() {
    tput clear
    tput bold
    centerMsg "\nMapR Distribution Initialization and Update\n"
    centerMsg "Copyright $(date +%Y) MapR Technologies, Inc., All Rights Reserved"
    centerMsg "http://www.mapr.com\n"
    tput sgr0
    checkOS
    unset ANSWER
    while [ -z "$ANSWER" ]; do
        prompt "$1? (\"q!\" to quit)" "Y"
        case "$ANSWER" in
        y*|Y*)
            ;;
        n*|N*)
            exit 0
            ;;
        *)  unset ANSWER
            ;;
        esac
    done
}

epilogue() {
    tput bold
    centerMsg "To continue installing MapR software, open the following URL in a web browser"
    centerMsg ""
    if [ "$HOSTNAME_INTERNAL" = "$HOSTNAME" ]; then
        centerMsg "If the address '$HOSTNAME' is internal and not accessible"
        centerMsg "from your browser, use the external address mapped to it instead"
        centerMsg ""
    fi
    centerMsg "https://$HOSTNAME:$MAPR_PORT"
    centerMsg ""
    tput sgr0
}

isUserRoot() {
    if [ $ID -ne 0 ]; then
        messenger $ERROR "$CMD must be run as 'root'"
    fi
}

# Refresh package manager and install package dependencies
fetchDependencies() {
    formatMsg "\nInstalling package dependencies ($DEPENDENCY)"
    case $OS in
    redhat)
        yum -q clean expire-cache
        if ! rpm -qa | grep -q epel-release; then
            yum -q -y install epel-release
            if [ $? -ne 0 ]; then
                if grep -q " 7." /etc/redhat-release; then
                    yum -q -y install http://dl.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-5.noarch.rpm
                elif grep -q " 6." /etc/redhat-release; then
                    yum -q -y install http://dl.fedoraproject.org/pub/epel/6/i386/epel-release-6-8.noarch.rpm
                fi
            fi
        fi
        yum --disablerepo=epel -q -y update ca-certificates
        yum -q -y install $DEPENDENCY
        ;;
    suse)
        zypper --non-interactive -q refresh
        if zypper --non-interactive -q install -n $DEPENDENCY; then
            ln -f -s /usr/lib64/libcrypto.so.1.0.0 /usr/lib64/libcrypto.so.10
            ln -f -s /usr/lib64/libssl.so.1.0.0 /usr/lib64/libssl.so.10
        else
            false
        fi
        ;;
    ubuntu)
        apt-get update -qq
        apt-get install -q -y $DEPENDENCY
        ;;
    esac
    if [ $? -ne 0 ]; then
        messenger $ERROR "Unable to install dependencies ($DEPENDENCY). Ensure that a core OS repo is enabled and retry $CMD"
    fi

    # if host is in EC2 or GCE, find external IP address from metadata server
    RESULTS=$(wget -q -O - -T1 -t1 http://169.254.169.254/latest/meta-data/public-ipv4)
    if [ $? -eq 0 ]; then
        HOSTNAME=$RESULTS
        MAPR_ENVIRONMENT=amazon
    else
        RESULTS=$(wget -q -O - -T1 -t1 --header "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)
        if [ $? -eq 0 ]; then
            HOSTNAME=$RESULTS
            MAPR_ENVIRONMENT=google
        fi
    fi

    formatMsg "\n...Success"
    testJDK
}

# Determine current OS
checkOS() {
    if [ -z "$HOSTNAME" ]; then
        messenger $ERROR "Hostname not configured properly. Correct the problem and re-run $CMD"
    fi
    if [ -f /etc/redhat-release ]; then
        OS=redhat
    elif [ -f /etc/SuSE-release ]; then
        OS=suse
        OSVER=$(grep VERSION /etc/SuSE-release | cut -d' ' -f3)
    elif uname -a | grep -q -i "ubuntu"; then
        OS=ubuntu
    else
        messenger $ERROR "$CMD must be run on RedHat, CentOS, SUSE, or Ubuntu Linux"
    fi
    if [ $(uname -p) != "x86_64" ]; then
        messenger $ERROR "$CMD must be run on a 64 bit version of Linux"
    fi
    case $OS in 
    redhat)
        DEPENDENCY=$DEPENDENCY_RPM
        HTTPD=$HTTPD_RPM
        HTTPD_REPO=$HTTPD_REPO_RPM
        MAPR_ARCHIVE=${MAPR_ARCHIVE:-$MAPR_ARCHIVE_RPM}
        OPENJDK=$OPENJDK_RPM
        ;;
    suse)
        DEPENDENCY=$DEPENDENCY_SUSE
	if [ $OSVER -ge 12 ]; then
            DEPENDENCY="python-pycurl $DEPENDENCY"
        else
            DEPENDENCY="python-curl $DEPENDENCY"
        fi
        HTTPD=$HTTPD_RPM
        HTTPD_REPO=$HTTPD_REPO_RPM
        MAPR_ARCHIVE=${MAPR_ARCHIVE:-$MAPR_ARCHIVE_RPM}
        OPENJDK=$OPENJDK_SUSE
        ;;
    ubuntu)
        DEPENDENCY=$DEPENDENCY_DEB
        HTTPD=$HTTPD_DEB
        HTTPD_REPO=$HTTPD_REPO_DEB
        MAPR_ARCHIVE=${MAPR_ARCHIVE:-$MAPR_ARCHIVE_DEB}
        OPENJDK=$OPENJDK_DEB
        ;;
    esac
}

# Test if JDK 7 or JDK 8 is installed
testJDK() {
    # if keytool exists, then JDK has been installed
    formatMsg "\nTesting for JDK 7 or 8..."
    if [ -n "$JAVA_HOME" ]; then
        KEYTOOL=$JAVA_HOME/bin/keytool
    else
        KEYTOOL=$(which keytool 2>/dev/null)
    fi

    # check if keytool is actually valid and exists
    if [ ! -e "${KEYTOOL:-}" ]; then
        messenger $WARN "JDK 1.7 or 1.8 not found or JAVA_HOME not set properly"
        fetchJDK 
    elif echo "$KEYTOOL" | grep -q "1.7|1.8"; then
        messenger $WARN "JDK not 1.7 or 1.8 not found"
        fetchJDK 
    fi
    formatMsg "...Success"
}

# Install OpenJDK if JDK 8 does not exist or the wrong version is installed
fetchJDK() {
    case $OS in
    redhat)
        yum -q -y install $OPENJDK
        ;;
    suse)
        zypper --non-interactive -q install -n $OPENJDK
        ;;
    ubuntu)
        apt-get install -q -y --force-yes $OPENJDK
        ;;
    esac
    if [ $? -ne 0 ]; then
        messenger $ERROR "Unable to install JDK 8 ($OPENJDK). Install manually and retry $CMD"
    fi
}

# Is there a webserver and is it listening on port 80.
# If port 80 is not listening, assume there's no web service.
# Prompt the user on whether to install apache2/httpd or continue
testPort80() {
    # If nothing is returned, then port 80 is not active
    if $(ss -lnt "( sport = :80 or sport = :443 )" | grep -q LISTEN); then
        formatMsg "Existing web server will be used to serve packages from this system"
    else
        formatMsg "No web server detected, but is required to serve packages from this system"

        unset ANSWER
        while [ -z "$ANSWER" ]; do
            prompt "Would you like to install a webserver on this system?  (\"q!\" to quit)?" "Y"
            case "$ANSWER" in
            n*|N*)
                return $NO
                ;;
            y*|Y*)
                fetchWebServer
                ;;
            *)  unset ANSWER
                ;;
            esac
        done
    fi
    return $YES
}

# If no web server was found, install and start apache2/httpd
fetchWebServer() {
    formatMsg "Installing web server..."
    case $OS in 
    redhat)
        yum -q -y install $HTTPD
        ;;
    suse)
        zypper --non-interactive -q install -n $HTTPD
        ;;
    ubuntu)
        apt-get install -q -y $HTTPD
        ;;
    esac

    if [ $? -ne 0 ]; then
        messenger $ERROR "Unable to install web server '$HTTPD'. Please correct the error and retry $CMD"
    fi

    # start newly installed web service
    case $OS in 
    redhat|suse)
        service $HTTPD start
        ;;
    ubuntu)
        service $HTTPD start
        ;;
    esac
    if [ $? -ne 0 ]; then
        messenger $ERROR "Unable to start web server. Please correct the error and retry $CMD"
    fi
}

# Test the connection MapR Techonolgies, Inc.  If a
# connection exists, then use the MapR URLs.  Othewise,
# prompt the user for the location of the MapR archive tarball
testConnection() {
    # If a MapR package tarball has been given, use that as the default
    ISCONNECTED=$NO
    if [ $TEST_CONNECT = $YES ]; then 
        formatMsg "\nTesting connection to $MAPR_PKG_URL...\c"
        if which wget > /dev/null 2>&1 && wget -q --spider "$MAPR_PKG_URL/" -O /dev/null; then
            formatMsg "...Success"
            ISCONNECTED=$YES
            return
        elif which curl > /dev/null 2>&1 && curl -f -s -o /dev/null "$MAPR_PKG_URL/"; then
            formatMsg "...Success"
            ISCONNECTED=$YES
            return
        elif ping -o -q  $(echo "$MAPR_PKG_URL/" | cut -d/ -f3) > /dev/null 2>&1; then
            formatMsg "...Success"
            ISCONNECTED=$YES
            return
        elif [ -n "$MAPR_INSTALLER_PACKAGES" ]; then
            messenger $ERROR "Connectivity to $MAPR_PKG_URL required"
        else
            formatMsg "...No connection found"
            formatMsg "Without connectivity to MapR Technologies ($MAPR_PKG_URL),
                the complete MapR archive tarball is required to complete this setup"

            prompt "Enter the path to the MapR archive (\"q!\" to quit)" "$MAPR_ARCHIVE"
            MAPR_ARCHIVE=$(cd "$(dirname $ANSWER)"; pwd)/$(basename $ANSWER)
            while [ ! -f "$MAPR_ARCHIVE" ]; do
                messenger $WARN "$MAPR_ARCHIVE: no such file"
                prompt "Enter the path for the MapR archive (\"q!\" to quit)" "$MAPR_ARCHIVE"
                MAPR_ARCHIVE=$(cd "$(dirname $ANSWER)"; pwd)/$(basename $ANSWER)
            done
        fi
    fi

    formatMsg "\nCreating local repo from $MAPR_ARCHIVE...\c"
    testPort80

    prompt "Enter the web server filesystem directory to extract the MapR archive to (\"q!\" to quit)" "$HTTPD_REPO"
    HTTPD_REPO=$ANSWER

    prompt "\nEnter web server url for this path (\"q!\" to quit)" "http://$HOSTNAME/$(basename $HTTPD_REPO)"
    MAPR_ECO_URL="$ANSWER"
    MAPR_CORE_URL="$ANSWER"

    formatMsg "\nExtracting packages from $MAPR_ARCHIVE...\c"
    [ -d $HTTPD_REPO/installer ] && rm -rf $HTTPD_REPO
    mkdir -p $HTTPD_REPO
    if ! tar -xvzf $MAPR_ARCHIVE -C $HTTPD_REPO; then
        messenger $ERROR "unable to extract archive file"
    fi
    formatMsg "\n...Success"
}

# ensure that root and admin users have correct permissions
checkSudo() {
    if ! su $MAPR_USER -c "id $MAPR_USER" > /dev/null 2>&1 ; then
        messenger $ERROR "User 'root' is unable to run services as user '$MAPR_USER'. Correct the problem and re-run $CMD"
    fi
    dir=$(getent passwd $MAPR_USER | cut -d: -f6)
    if [ -d "$dir" ] && ! su $MAPR_USER -c "test -O $dir -a -w $dir" ; then
        messenger $ERROR "User '$MAPR_USER' does not own and have permissions to write to '$dir'. Correct the problem and re-run $CMD"
    fi
    gid=$(stat -c '%G' /etc/shadow)
    if [ $MAPR_USER_CREATE = false ] && ! id -Gn $MAPR_USER | grep -q $gid ; then
        messenger $WARN "User '$MAPR_USER' must be in group '$gid' to allow UNIX authentication"
    fi
    formatMsg "...Success"
}

# If a 'mapr' user account does not exist or a user
# defined account does not exist, create a 'mapr' user account
createUser() {
    formatMsg "Testing for cluster admin account..."
    tput sgr0
    prompt "Enter MapR cluster admin user name (\"q!\" to quit)" "$MAPR_USER" 
    TMP_USER=$ANSWER
    while [ "$TMP_USER" = root ]; do
        messenger $WARN "Cluster admin cannot be root user"
        prompt "Enter MapR cluster admin user name (\"q!\" to quit)" "$MAPR_USER" 
        TMP_USER=$ANSWER
    done

    MAPR_USER=$TMP_USER

    set -- $(getent passwd $MAPR_USER | tr ':' ' ')
    TMP_UID=$3
    TMP_GID=$4
    
    # If the given/default user name is valid, set the
    # returned uid and gid as the mapr user
    if [ -n "$TMP_UID" ] && [ -n "$TMP_GID" ]; then 
        MAPR_UID=$TMP_UID
        MAPR_GID=$TMP_GID
        MAPR_GROUP=$(getent group $MAPR_GID | cut -d: -f1)
        checkSudo
        return
    fi

    formatMsg "\nUser '$MAPR_USER' does not exist. Creating new cluster admin account..."

    # ensure that the given/default uid doesn't already exist
    if getent passwd $MAPR_UID > /dev/null 2>&1 ; then
        MAPR_UID=""
    fi
    prompt "Enter '$MAPR_USER' uid (\"q!\" to quit)" "$MAPR_UID"
    TMP_UID=$ANSWER
    while getent passwd $TMP_UID > /dev/null 2>&1 ; do
        messenger $WARN "uid $TMP_UID already exists"
        prompt "Enter '$MAPR_USER' uid (\"q!\" to quit)" "$MAPR_UID"
        TMP_UID=$ANSWER
    done
    MAPR_UID=$TMP_UID

    # prompt the user for the mapr user's group
    prompt "Enter '$MAPR_USER' group name (\"q!\" to quit)" "$MAPR_GROUP"
    MAPR_GROUP=$ANSWER

    set -- $(getent group $MAPR_GROUP | tr ':' ' ')
    TMP_GID=$3
    
    # if the group id does not exist, then this is a new group
    if [ -z "$TMP_GID" ]; then
        # ensure that the default gid does not already exist
        if getent group $MAPR_GID > /dev/null 2>&1 ; then
            MAPR_GID=""
        fi

        # prompt the user for a group id
        prompt "Enter '$MAPR_GROUP' gid (\"q!\" to quit)" "$MAPR_GID"
        TMP_GID=$ANSWER

        # verify that the given group id doesn't already exist
        while getent group $TMP_GID > /dev/null 2>&1 ; do
            messenger $WARN "gid $TMP_GID already exists"
            prompt "Enter '$MAPR_GROUP' gid (\"q!\" to quit)" "$MAPR_GID"
            TMP_GID=$ANSWER
        done

        # create the new group with the given group id
        RESULTS=$(groupadd -g $TMP_GID $MAPR_GROUP 2>&1)
        if [ $? -ne 0 ]; then
            messenger $ERROR "Unable to create group $MAPR_GROUP: $RESULTS"
        fi
        MAPR_GROUP_CREATE=true
    fi
    MAPR_GID=$TMP_GID

    # prompt for password
    [ -z "$MAPR_PASSWORD" -a $PROMPT_SILENT = $YES ] && MAPR_PASSWORD=$MAPR_USER
    prompt "Enter '$MAPR_USER' password (\"q!\" to quit)" "$MAPR_PASSWORD" -s
    MAPR_PASSWORD=$ANSWER
    if [ $PROMPT_SILENT = $YES ]; then
        TMP_PASSWORD=$ANSWER
    else
        prompt "Confirm '$MAPR_USER' password (\"q!\" to quit)" "" -s
        TMP_PASSWORD=$ANSWER
    fi
    while [ "$MAPR_PASSWORD" != "$TMP_PASSWORD" ]; do
        messenger $WARN "Password for '$MAPR_USER' does not match"
        prompt "Enter '$MAPR_USER' password (\"q!\" to quit)" "" -s
        MAPR_PASSWORD=$ANSWER
        prompt "Confirm '$MAPR_USER' password (\"q!\" to quit)" "" -s
        TMP_PASSWORD=$ANSWER
    done

    # create the new user with the default/given uid and gid
    # requires group read access to /etc/shadow for PAM auth
    RESULTS=$(useradd -m -u $MAPR_UID -g $MAPR_GID -G $(stat -c '%G' /etc/shadow) $MAPR_USER 2>&1)
    if [ $? -ne 0 ]; then
        messenger $ERROR "Unable to create user $MAPR_USER: $RESULTS"
    fi

    passwd $MAPR_USER > /dev/null 2>&1 << EOM
$MAPR_PASSWORD
$MAPR_PASSWORD
EOM
    MAPR_USER_CREATE=true
    checkSudo
}

# Install the RedHat/CentOS version of the MapR installer
fetchInstaller_redhat() {
    formatMsg "Installing packages..."
    setenforce 0 > /dev/null 2>&1
    if [ -n "$MAPR_INSTALLER_PACKAGES" ]; then
        yum -q -y install $MAPR_INSTALLER_PACKAGES
    elif [ "$ISCONNECTED" = "$YES" ]; then
        # Create the mapr-installer repository information file
        [ "$MAPR_CORE_URL" = "$MAPR_ECO_URL" ] && subdir="/redhat"
        cat > /etc/yum.repos.d/mapr_installer.repo << EOM
[MapR_Installer]
name=MapR Installer
baseurl=$MAPR_INSTALLER_URL$subdir
gpgcheck=0

EOM
        yum -q -y makecache fast
        yum --disablerepo=* --enablerepo=epel,MapR_Installer -q -y install mapr-installer-definitions mapr-installer
    else
        (cd $HTTPD_REPO/installer/redhat ; yum -q -y --nogpgcheck localinstall mapr-installer*)
    fi

    if [ $? -ne 0 ]; then
        messenger $ERROR "Unable to install packages. Please correct the error and retry $CMD"
    fi

    # disable firewall on initial install
    if which systemctl > /dev/null 2>&1; then
        systemctl disable firewalld > /dev/null 2>&1
        systemctl stop firewalld > /dev/null 2>&1
    fi
    service iptables stop > /dev/null 2>&1 && chkconfig iptables off > /dev/null 2>&1

    formatMsg "\n...Success"
}

# Install the SuSE version of the MapR installer
fetchInstaller_suse() {
    formatMsg "Installing packages..."
    if [ -n "$MAPR_INSTALLER_PACKAGES" ]; then
        zypper --non-interactive -q install -n $MAPR_INSTALLER_PACKAGES
    elif [ $ISCONNECTED = $YES ]; then
        # Create the mapr-installer repository information file
        [ "$MAPR_CORE_URL" = "$MAPR_ECO_URL" ] && subdir="/suse"
        cat > /etc/zypp/repos.d/mapr_installer.repo << EOM
[MapR_Installer]
name=MapR Installer
baseurl=$MAPR_INSTALLER_URL$subdir
gpgcheck=0

EOM
        # Install mapr-installer
        zypper --non-interactive -q install -n mapr-installer-definitions mapr-installer
    else
        (cd $HTTPD_REPO/installer/suse ; zypper --non-interactive -q install -n ./mapr-installer*)
    fi

    if [ $? -ne 0 ]; then
        messenger $ERROR "Unable to install packages. Please correct the error and retry $CMD"
    fi

    formatMsg "\n...Success"
}

# Install the Ubuntu version of the MapR installer
fetchInstaller_ubuntu() {
    formatMsg "Installing packages..."
    aptsources="-o Dir::Etc::SourceList=/etc/apt/sources.list.d/mapr_installer.list"
    if [ -n "$MAPR_INSTALLER_PACKAGES" ]; then
        dpkg -i $MAPR_INSTALLER_PACKAGES
        apt-get update -qq
        apt-get install -f --force-yes -y
    elif [ "$ISCONNECTED" = "$YES" ]; then
        # Create the custom source list file
        mkdir -p /etc/apt/sources.list.d
        [ "$MAPR_CORE_URL" = "$MAPR_ECO_URL" ] && subdir="/ubuntu"
        cat > /etc/apt/sources.list.d/mapr_installer.list << EOM
deb $MAPR_INSTALLER_URL$subdir binary/
EOM

        # update repo info and install mapr-installer
        apt-get -q $aptsources update
        apt-get $aptsources -q install -y --force-yes mapr-installer-definitions mapr-installer
    else
        (cd $HTTPD_REPO/installer/ubuntu/dists/binary ; dpkg -i mapr-installer*)
    fi

    if [ $? -ne 0 ]; then
        messenger $ERROR "Unable to install packages. Please correct the error and retry $CMD"
    fi

    formatMsg "\n...Success"
}

fetchVersions_redhat() {
    MAPR_DEF_VERSION=$(rpm -q --queryformat '%{VERSION}\n' mapr-installer-definitions | tail -n1)
    MAPR_SERVER_VERSION=$(rpm -q --queryformat '%{VERSION}\n' mapr-installer | tail -n1)
}

fetchVersions_suse() {
    MAPR_DEF_VERSION=$(rpm -q --queryformat '%{VERSION}\n' mapr-installer-definitions | tail -n1)
    MAPR_SERVER_VERSION=$(rpm -q --queryformat '%{VERSION}\n' mapr-installer | tail -n1)
}

fetchVersions_ubuntu() {
    MAPR_DEF_VERSION=$(dpkg -s mapr-installer-definitions | grep -i version | head -1 | awk '{print $NF}')
    MAPR_SERVER_VERSION=$(dpkg -s mapr-installer | grep -i version | head -1 | awk '{print $NF}')
}

createPropertiesFile() {
    if [ $ISUPDATE = $YES -a -f "$MAPR_PROPERTIES_FILE" ]; then
        updatePropertiesFile
    else
        mkdir -m 700 -p $MAPR_DATA_DIR
        cat > "$MAPR_PROPERTIES_FILE" << EOM
{
    "cluster_admin_create": $MAPR_USER_CREATE,
    "cluster_admin_gid": $MAPR_GID,
    "cluster_admin_group": "$MAPR_GROUP",
    "cluster_admin_id": "$MAPR_USER",
    "cluster_admin_uid": $MAPR_UID,
    "debug": false,
    "environment": "$MAPR_ENVIRONMENT",
    "port": $MAPR_PORT,
    "repo_core_url": "$MAPR_CORE_URL",
    "repo_eco_url": "$MAPR_ECO_URL",
    "installer_version": "$MAPR_SERVER_VERSION",
    "services_version": "$MAPR_DEF_VERSION"
}
EOM
    fi
}

reloadPropertiesFile() {
    if [ -f /etc/init.d/mapr-installer ]; then
        RESULTS=$(service mapr-installer condreload)
        if [ $? -ne 0 ]; then
            messenger $ERROR "mapr-installer reload failed: $RESULTS"
        fi
    fi
}

startServer() {
    RESULTS=$(service mapr-installer condstart)
    if [ $? -ne 0 ]; then
        messenger $ERROR "mapr-installer start failed: $RESULTS"
    fi
}

updatePropertiesFile() {
    sed -i -e "s/\"installer_version.*/\"installer_version\": \"$MAPR_SERVER_VERSION\",/" -e "s/\"services_version.*/\"services_version\": \"$MAPR_DEF_VERSION\"/" "$MAPR_PROPERTIES_FILE"
}

# this is an update if mapr-installer package exists
isUpdate() {
    case $OS in
    redhat|suse)
        rpm -qa | grep -q mapr-installer 2>&1 && ISUPDATE=$YES
        ;;
    ubuntu)
        dpkg -l | grep "^ii" | grep -q mapr-installer 2>&1 && ISUPDATE=$YES
        ;;
    esac

    if [ $ISUPDATE = $NO ] && $(ss -lnt "( sport = :$MAPR_PORT )" | grep -q LISTEN); then
        messenger $ERROR "Port $MAPR_PORT is in use. Correct the problem and re-run $CMD"
    fi
}

# Remove all packages
remove() {
    formatMsg "\nUninstalling packages..."
    pkgs="mapr-installer mapr-installer-definitions"
    service mapr-installer condstop > /dev/null
    case $OS in
    redhat)
        rm -f /etc/yum.repos.d/mapr_installer.repo
        yum -q -y remove $pkgs
        ;;
    suse)
        rm -f etc/zypp/repos.d/mapr_installer.repo
        zypper --non-interactive -q remove $pkgs
        ;;
    ubuntu)
        rm -f /etc/apt/sources.list.d/mapr_installer.list
        apt-get purge -q -y $pkgs
        ;;
    esac
    if [ $? -ne 0 ]; then
        messenger $ERROR "Unable to remove packages ($pkgs)"
    fi
    rm -rf /opt/mapr/installer

    formatMsg "\n...Success"
}


##
## MAIN
##

set -x

[ -z "${TERM:-}" ] && export TERM=ansi

tput init

# Parse command line and set globals
while [ $# -gt 0 ] && [ -z "${1##-*}" ] ; do
    case "$1" in
    -a|--archive)
        [ $# -gt 1 ] || usage
        MAPR_ARCHIVE=$2
        TEST_CONNECT=$NO
        shift 1
        ;;
    -f|--force)
        PROMPT_FORCE=$YES
        ;;
    -h|-\?|--help)
        usage 0
        ;;
    -i|--install)
        [ $# -gt 2 ] || usage
        MAPR_INSTALLER_PACKAGES="$2 $3"
        shift 2
        ;;
    -p|--port)
        [ $# -gt 1 ] || usage
        MAPR_PORT=$2
        shift 1
        ;;
    -r|--repo)
        [ $# -gt 1 ] || usage
        MAPR_INSTALLER_URL=$2/installer
        MAPR_CORE_URL=$2
        MAPR_ECO_URL=$2
        shift 1
        ;;
    -u|--urls)
        [ $# -gt 3 ] || usage
        MAPR_INSTALLER_URL=$2
        MAPR_CORE_URL=$3
        MAPR_ECO_URL=$4
        shift 3
        ;;
    -y|--yes)
        PROMPT_SILENT=$YES
        ;;
    *)
        usage
        ;;
    esac
    shift
done

case "$1" in
""|install)
    # If mapr-installer has been installed, then do an update.
    # Otherwise, prepare the system for MapR installation
    prologue "Install packages"
    isUserRoot
    # Set traps so the installation script always exits cleanly
    trap catchTrap 1 2 3 10 15
    [ $PROMPT_FORCE = $NO ] && isUpdate
    fetchDependencies
    testConnection
    [ $ISUPDATE = $NO ] && createUser
    fetchInstaller_$OS
    fetchVersions_$OS
    createPropertiesFile
    startServer
    epilogue
    ;;
reload)
    checkOS
    fetchVersions_$OS
    updatePropertiesFile
    reloadPropertiesFile
    ;;
remove)
    prologue "Remove packages"
    isUserRoot
    remove
    ;;
update)
    prologue "Update packages"
    isUserRoot
    trap catchTrap 1 2 3 10 15
    testConnection
    ISUPDATE=$YES
    fetchInstaller_$OS
    fetchVersions_$OS
    updatePropertiesFile
    reloadPropertiesFile
    startServer
    epilogue
    ;;
*)
    usage
    ;;
esac

set +x

