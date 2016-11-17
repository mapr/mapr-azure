#!/usr/bin/perl
$myname=`hostname`; chomp $myname;

$success=1;

if ($myname eq $ARGV[0]){
 print "this is the first node\n";
 system("yum -y install httpd");
 system("mkdir -p /root/.ssh");
 system("cp ~$ARGV[1]/.ssh/authorized_keys /root/.ssh");
 system("rm -f /root/.ssh/id_rsa.pub");
 system("cp ~$ARGV[1]/.ssh/id_rsa /root/.ssh");
 system("cp ~$ARGV[1]/.ssh/config /root/.ssh");
 system("cp ~$ARGV[1]/.ssh/authorized_keys /var/www/html/key");
 system("chmod 755 /var/www/html/key");
 system("service httpd restart");

$nlist=`awk '{print $1}' /tmp/maprhosts`;chomp $nlist;
@nlist=split(/\n/,$nlist);
$num_nodes=$#nlist+1;
$count=0;

while ($count != $num_nodes){
foreach $h (@nlist){
  `ssh -oBatchMode=yes $h ls /tmp`;
  $sshOK=$?;
  if ($sshOK == 0){$count++}
  print "$count nodes done out of $num_nodes nodes \n";
}
sleep 2;
if ($count == $num_nodes){last;}else{$count=0}
}
print "All nodes ready....\n";
system("service httpd stop;chkconfig off");
system("rm -f /var/www/html/key");

}else{

while ($success != 0){
  print "Waiting to copy keys...\n";
  sleep 2;
  `wget http://$ARGV[0]/key -O /tmp/authorized_keys`;
  $success=$?;
}
  print "Key copying succeeded\n";
  system("mkdir -p /root/.ssh");
  system("cp /tmp/authorized_keys /root/.ssh/authorized_keys");
}

