#!/usr/bin/env perl

#
# Copyright (c) 2009 & onwards. MapR Tech, Inc., All rights reserved
#

use Getopt::Std;

use strict;
use warnings;

my $MapRHome = $ENV{"MAPR_HOME"};
if (! defined $MapRHome) {
  $MapRHome = "/opt/mapr";
}

##########
# Logging
##########
my $logFile = "$MapRHome/logs/mount_local_fs.log";
# re-direct stderr to stdout
open (STDOUT, ">> $logFile");
open (STDERR, ">&STDOUT");
my $mode = 0600;
chmod $mode, $logFile;

###########
# globals
###########

my $cmdName = $0;
my $debug = 0;
my $MapRFsTab = "$MapRHome/conf/mapr_fstab";
my $MapRExecute = "$MapRHome/server/maprexecute";

###########
# Methods
###########

sub RunCommand ($ $)
{
  my ($cmd, $msg) = @_;

  my @out = `$cmd 2>&1`;
  my $ret = $? >> 8;

  if ($debug) {
    printf ("%s [DEBUG]: cmd=%s, output=@out", scalar(localtime()), $cmd);
  }

  if ($ret != 0) {
    printf "%s [ERROR] %s failed: ret=%d, o/p: @out",
      scalar(localtime()), $msg, $ret;
  }

  return $ret;
}

sub RunMountCmd($$$)
{
  my ($opts, $nfsInfo, $dir) = @_;
  my $cmd = "";
  if ( $< == 0 ) {
    $cmd = "/bin/mount -o $opts $nfsInfo $dir";
  } else {
    $cmd = "$MapRExecute mount -o $opts $nfsInfo $dir";
  }
  my $ret = RunCommand($cmd, "Mounting $dir");
  return $ret;
}

sub LogInfo ( $ ) 
{
  my ($msg) = @_;
  printf ("%s [INFO] %s\n", scalar(localtime()), $msg);
}

sub IsMounted($$)
{
  my ($mnt, $array_reference) = @_;
  my @cmdOut = @$array_reference;

  my $ret = 1;

  # o/p fmt: localhost:/mapr on /mapr type nfs (rw,soft,intr,addr=127.0.0.1)
  foreach my $line (@cmdOut) {
    my @arr = split (/\s+/, $line);
    my $nfsInfo  = $arr[0];
    my $mntPoint = $arr[2];

    if ($mntPoint eq $mnt) {
      $ret = 0;
      last;
    }
  }

  return $ret;
}

sub IsNFSServerRunning()
{
  my $cmd;
  my $ret = -1;

  if (-e "$MapRHome/initscripts/mapr-nfsserver") {
    $cmd = "$MapRHome/initscripts/mapr-nfsserver  status";
    $ret = RunCommand($cmd, "Checking if NFS server is running");

	# Confirm that we have the necessary license
    if ($ret == 0 && -e "$MapRHome/bin/maprcli") {
      $cmd = "$MapRHome/bin/maprcli license apps -noheader | grep -q -w NFS";
      $ret = RunCommand($cmd, "Checking if cluster is licensed for NFS");
    }
  }

  # Check if loop back nfs is running if nfsserver is not up. 
  if ($ret != 0 && -e "$MapRHome/initscripts/mapr-loopbacknfs") {
    $cmd = "$MapRHome/initscripts/mapr-loopbacknfs  status";
    $ret = RunCommand($cmd, "Checking if loopback NFS is running");

	# Confirm that we have the necessary license
    if ($ret == 0 && -e "$MapRHome/bin/maprcli") {
      $cmd = "$MapRHome/bin/maprcli license apps -noheader | grep -q -w NFS_CLIENT";
      $ret = RunCommand($cmd, "Checking if cluster is licensed for NFS_CLIENT");
    }
  }

  return $ret;
}

sub UnMount($)
{
  my ($mnt) = @_;
  my $cmd = "";
  if ( $< == 0 ) {
    $cmd = "/bin/umount -f $mnt";
  } else {
    $cmd = "$MapRExecute umount -f $mnt";
  }
  my $ret = RunCommand($cmd, "UnMounting $mnt");
  return $ret;
}

sub MountEntry($$)
{
  my ($entry, $array_reference) = @_;
  my @mountOutput = @$array_reference;

  my $needToMount = 0;
  my ($nfsInfo, $mnt, $opts) = split (/\s+/, $entry);

  if (IsMounted ($mnt, \@mountOutput) != 0) {
    $needToMount = 1;
  }

  my $ret = 0;
  if ($needToMount) {
    $ret = RunMountCmd($opts, $nfsInfo, $mnt);
    if ($ret == 0) {
      LogInfo ("$mnt mounted successfully");
    } else {
      $ret = 1; # return 0 for success, 1 for failure
    }
  } else {
    LogInfo ("$mnt already mounted");
    $ret = 0;
  }

  return $ret;
}

sub ReadMapRFstab()
{
  my @entries = ();
  my $ret = open (FSTAB, "<", $MapRFsTab);
  if (!defined $ret || $ret == 0) {
    printf ("%s [ERROR] reading $MapRFsTab: $!\n", scalar(localtime()));
    return \@entries;
  }

  my @lines = <FSTAB>;
  foreach my $line (@lines) {
    chomp ($line);

    next if (length ($line) == 0); # skip empty lines
    next if ($line =~ /^#/); # skip comments

    push (@entries, $line);
  }

  close (FSTAB);
  return \@entries;
}

#########
# main
#########

if (! -r $MapRFsTab) {
  # Nothing to do, so dont log anything
  exit (0);
}

my $path = $ENV{"PATH"};
$path = $path . ":/sbin:/usr/sbin";
$ENV{"PATH"} = $path;

my $RetryInterval = 20; # seconds
my $attemptNum = 0;

my $cmd = "cat $MapRHome/MapRBuildVersion";
my $version = `$cmd`;
chomp ($version);

LogInfo ("**** Started $cmdName $version ****");
LogInfo ("  ARGS = @ARGV");

#
# options:
#  u: unmount
#  n: no sleep
#
my %options=();
getopts("un", \%options);

# Read the mapr_fstab and get the entries
my $array_reference = ReadMapRFstab();
my @mounts = @$array_reference;

my $size = scalar(@mounts);
if ($size == 0) {
  LogInfo ("Nothing to mount/unmount");
  exit (0);
}

if (defined $options{u}) {
  # unmount
  LogInfo ("Attempting to umount directories");

  foreach my $entry (@mounts) {
    my ($nfsInfo, $mnt, $opts) = split (/\s+/, $entry);
    LogInfo ("UnMounting $mnt");
    UnMount($mnt);
  }

  exit (0);
}

# mount
if (! defined $options{n}) {
  # we'll be started by nfsserver startup script. So wait for sometime
  # to enable nfsserver to come up.
  sleep (5);
}

while (1) {
  LogInfo ("Attempting to mount directories: attempt #: $attemptNum");

  my $ret = IsNFSServerRunning();
  if ($ret != 0) {
    LogInfo ("NFS Server not running");
    last;
  }

  my $cmd = "mount"; # list all mounts
  my @out = `$cmd`;
  $ret = $? >> 8;

  if ($ret != 0) {
    printf ("%s [ERROR] cmd=%s, failed\n", scalar(localtime()), $cmd);
    LogInfo ("Retrying mount(s) in $RetryInterval seconds");
    sleep ($RetryInterval); #retry

    next;
  }

  if ($debug) {
    printf ("%s [DEBUG] cmd=%s, output=@out", scalar(localtime()), $cmd);
    my $len = scalar (@out);
    if ($len == 0) {
      printf ("\n");
    }
  }

  my $status = 0;
  foreach my $entry (@mounts) {
    $status += MountEntry ($entry, \@out); 
  }

  if ($status == 0) {
    last; #done
  } else {
    LogInfo ("Retrying mount(s) in $RetryInterval seconds");
    sleep ($RetryInterval); #retry
  }

  $attemptNum++;
}

exit 0;
