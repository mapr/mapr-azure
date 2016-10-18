#!/usr/bin/perl
use Switch;

sub core_inst{
$clustername=$_[0];
$clushf="/etc/clustershell/groups.d/local.cfg";
$tmp=`awk '{print \$1}' /tmp/maprhosts`;chomp $tmp;
@tmp=split(/\n/,$tmp);

$nnodes=$#tmp+1;

if ($tmp[0]=~/^(.*)node(\d+)$/){
$nbase=$1 . "node";
}

system("sed -i \"s/^all:.*/all:$nbase\[0-$#tmp]/g\" $clushf");

switch($nnodes){
case 1 {@zk=qw(0);@cldb=qw(0);@rm=qw(0);@hs=qw(0);@web=qw(0);@sparkhist=qw(0);}
case 2 {@zk=qw(0);@cldb=qw(0);@rm=qw(0);@hs=qw(0);@web=qw(0);@sparkhist=qw(0);}
case 3 {@zk=qw(0 1 2);@cldb=qw(0 1);@rm=qw(0 1);@hs=qw(2);@web=qw(0);@sparkhist=qw(2);}
case 4 {@zk=qw(0 1 2);@cldb=qw(0 1);@rm=qw(0 1);@hs=qw(2);@web=qw(0);@sparkhist=qw(2);}
case 5 {@zk=qw(0 1 2);@cldb=qw(0 1);@rm=qw(0 1);@hs=qw(2);@web=qw(0);@sparkhist=qw(2);}
else {@zk=qw(0 1 2);@cldb=qw(3 4 5);@rm=qw(4 5);@hs=qw(4);@web=qw(0 1);@sparkhist=qw(2);}
}

@ot=@hs;
@es=$rm[0];

$zk="zk:";
foreach $h (@zk){
$zk= $zk . $nbase . $h . ",";
}
chop $zk;

$cldb="cldb:";
foreach $h (@cldb){
$cldb= $cldb . $nbase . $h . ",";
}
chop $cldb;

$rm="rm:";
foreach $h (@rm){
$rm= $rm . $nbase . $h . ",";
}
chop $rm;

$hs="hs:";
foreach $h (@hs){
$hs= $hs . $nbase . $h . ",";
}
chop $hs;

$web="web:";
foreach $h (@web){
$web= $web . $nbase . $h . ",";
}
chop $web;

$sparkhist="sparkhist:";
foreach $h (@sparkhist){
$sparkhist= $sparkhist . $nbase . $h . ",";
}
chop $sparkhist;

$ot="ot:";
foreach $h (@ot){
$ot= $ot . $nbase . $h . ",";
}
chop $ot;

$es="es:";
foreach $h (@es){
$es= $es . $nbase . $h . ",";
}
chop $es;

open(FILE,">>$clushf");
print FILE "$cldb\n$zk\n$rm\n$hs\n$web\n$sparkhist\n$ot\n$es\n";
close(FILE);

$javav=`rpm -qa |  grep openjdk | head -1 | awk -F\- '{print \$1"-"\$2"-"\$3}'`; chomp $javav;

$inst_script="
clush -ac /etc/hosts --dest /etc/hosts
clush -g zk yum install mapr-zookeeper -y
clush -a yum install mapr-fileserver mapr-nfs mapr-nodemanager -y
clush -g cldb yum install mapr-cldb -y
clush -g rm yum install mapr-resourcemanager -y
clush -g hs yum install mapr-historyserver -y
clush -g web yum install mapr-webserver -y

clush -a /opt/mapr/server/configure.sh -C `nodeset -S, -e \@cldb` -Z `nodeset -S, -e \@zk` -N $clustername -RM `nodeset -S, -e \@rm` -HS `nodeset -S, -e \@hs` -no-autostart

clush -a /opt/mapr/server/disksetup -F /tmp/MapR.disks

clush -a \"sed -i 's/#export JAVA_HOME=/export JAVA_HOME=\\/usr\\/lib\\/jvm\\/$javav/g' /opt/mapr/conf/env.sh\"

clush -a mkdir -p /mapr
echo \"localhost:/mapr  /mapr  hard,nolock\" > /opt/mapr/conf/mapr_fstab
clush -ac /opt/mapr/conf/mapr_fstab --dest /opt/mapr/conf/mapr_fstab

clush -a service mapr-zookeeper start
clush -a service mapr-warden start
";

$spyglassf="
clush -a yum install mapr-collectd mapr-fluentd -y
clush -g ot yum install mapr-grafana mapr-opentsdb -y
clush -g es yum install mapr-elasticsearch mapr-kibana -y
clush -a \"/opt/mapr/server/configure.sh -R -ES `nodeset -S, -e \@es` -OT `nodeset -S, -e \@ot` >& /dev/null \"

#clush -a service mapr-warden restart
";

open(INST,">/tmp/mapr_install.sh");
print INST $inst_script;
close(INST);

open(INST,">/tmp/spyglass.sh");
print INST $spyglassf;
close(INST);

$lic=`cat /tmp/maprlicensetype`;chomp $lic;
if ($lic eq "convergedCommunity") {system("/home/mapr/sbin/rlc.sh.x");}

system("sh /tmp/mapr_install.sh");

#wait for the cluster to be ready
$checkfs=$checkmcs=$mtime=0;
do{

`hadoop fs -stat / >& /dev/null`; 
$fs=$?;
if ($fs == 0){$checkfs=1}else{$checkfs=0}

`lsof -i :8443 | grep -i listen >& /dev/null`;
$mcs=$?; 
if ($mcs == 0){$checkmcs=1}else{$checkmcs=0}

print "Waiting for base cluster to be ready...\n";
sleep 2;
$mtime=$mtime+2;

if ($mtime >=100){print "Cluster failed to install\n";exit 1;}

}until($checkfs==1 & $checkmcs==1);

print "Installing MapR Monitoring....\n";
system("sh /tmp/spyglass.sh");

print "Cluster is ready...\n";

} #core

sub hiveserver_inst{
$hive_config_file="/opt/mapr/hive/hive-1.2/conf/hive-site.xml";
$headnode=`head -1 /tmp/maprhosts | awk '{print $1}'`;chomp $headnode;
$mysql_user=$_[0];
$mysql_passwd=$_[1];
$sudo_user=$_[2];
system("yum -y install mysql-server mapr-hivemetastore");
system("chkconfig mysqld on; service mysqld start");
sleep 3;
system("mysqladmin -u $mysql_user password $mysql_passwd");

$hive_srv_config=
"<property><name>javax.jdo.option.ConnectionURL<\\/name><value>jdbc:mysql:\\/\\/localhost:3306\\/hive?createDatabaseIfNotExist=true<\\/value><\\/property>\\n<property><name>javax.jdo.option.ConnectionDriverName<\\/name><value>com.mysql.jdbc.Driver<\\/value><\\/property>\\n<property><name>javax.jdo.option.ConnectionUserName<\\/name><value>$mysql_user<\\/value><\\/property>\\n<property><name>javax.jdo.option.ConnectionPassword<\\/name><value>$mysql_passwd<\\/value><\\/property>\\n<property><name>hive.metastore.warehouse.dir<\\/name><value>\\/user\\/hive\\/warehouse<\\/value><\\/property>\\n<property><name>hive.metastore.uris<\\/name><value>thrift:\\/\\/localhost:9083<\\/value><\\/property>\\n<property><name>datanucleus.autoCreateSchema<\\/name><value>true<\\/value><\\/property>\\n<property><name>datanucleus.autoCreateTables<\\/name><value>true<\\/value><\\/property>\\n<\\/configuration>";

#print "sed -e \"s/<\\/configuration>\/$hive_srv_config\/g\" $hive_config_file\n"; 
system("sed -i \"s/<\\/configuration>\/$hive_srv_config\/g\" $hive_config_file\n"); 
system("yum -y install mapr-hiveserver2");
system("clush -a /opt/mapr/server/configure.sh -R"); 
sleep 20;
`maprcli node services -name hivemeta -action stop -nodes $headnode >& /dev/null`;
`maprcli node services -name hs2 -action stop -nodes $headnode >& /dev/null`;
`maprcli node services -name hivemeta -action start -nodes $headnode >& /dev/null`;
`maprcli node services -name hs2 -action start -nodes $headnode >& /dev/null`;

while ($hivetmp != 0 | $hstmp != 0){
print "Waiting for hivemeta and hs2 to come up....\n";
`lsof -i :9083 | grep -i listen`;
$hivetmp=$?;
`lsof -i :10000 | grep -i listen`;
$hstmp=$?;
sleep 3;
}
print "Hive Server is ready.\n";
system("hadoop fs -mkdir -p /user/$sudo_user/tmp/hive");
system("hadoop fs -mkdir -p /user/hive");
system("hadoop fs -mkdir -p /apps/spark");
system("hadoop fs -chown -R $sudo_user /user/$sudo_user");
system("hadoop fs -chgrp -R $sudo_user /user/$sudo_user");
system("hadoop fs -chown -R mapr /user/hive");
system("hadoop fs -chgrp -R mapr /user/hive");
system("hadoop fs -chmod -R 777 /user/$sudo_user/tmp");
system("hadoop fs -chmod -R 777 /user/hive");
system("hadoop fs -chown -R $sudo_user /apps");
system("hadoop fs -chgrp -R $sudo_user /apps");

#install drill
print "Installing Drill..\n";
system("clush -a yum -y install mapr-drill");
system("clush -a /opt/mapr/server/configure.sh -R");
#system("clush -a \"sed -i 's/^DRILL_MAX_DIRECT_MEMORY.*/DRILL_MAX_DIRECT_MEMORY=3G/g' `find /opt/mapr/drill -name drill-env.sh`\"");
#system("clush -a \"sed -i 's/^DRILL_HEAP=.*/DRILL_HEAP=2G/g' `find /opt/mapr/drill -name drill-env.sh`\"");

#install spark
print "Installing Spark..\n";
system("clush -a yum -y install mapr-spark");
#system("clush -g sparkhist yum -y install mapr-spark-historyserver");
system("hadoop fs -mkdir /apps/spark; hadoop fs -chmod 777 /apps/spark");
} #hiveserver

sub post_inst{
#system("clush -a \"sed -i 's/#PermitRootLogin.*/PermitRootLogin no/g' /etc/ssh/sshd_config\"");
#system("clush -a service sshd restart");
system("rm -rf /tmp/mapr_install.sh");
system("rm -rf /tmp/spyglass.sh");
$lic=`cat /tmp/maprlicensetype`;chomp $lic;
if ($lic eq "convergedEnterprise") {$licf="~mapr/licenses/azureCE_200.txt";}
if ($lic eq "Enterprise") {$licf="~mapr/licenses/azureE_200.txt";}
system("maprcli license add -license $licf -is_file true");
sleep 10;
system("/home/mapr/sbin/rlc.sh.x");
print "Cluster is ready.\n";
} #post_inst


#main
print "Installing MapR Core...\n";
&core_inst(($ARGV[$#ARGV]));
print "Installing Hive metastore and Hive server ...\n";
&hiveserver_inst(@ARGV);
&post_inst(@ARGV);
