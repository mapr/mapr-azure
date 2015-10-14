# Advanced Linux Template : Deploy a Multi VM MapR Cluster

<a href="https://azuredeploy.net/" target="_blank">
    <img src="http://azuredeploy.net/deploybutton.png"/>
</a>


<h1>
BETA RELEASE
</h1>

This advanced template creates a Multi VM MapR Cluster.  Users can 
select which instance types to use; storage for each node is 
currently defined in the template itself (scaled to 2 1TB volumes 
per vcore for each instance type).

The Control System interface to the cluster will be available at
    https://[cluster_node_0]:8443

The installation itself utilizes the MapR Installer service
(deployed on node0).   Should you wish to install additional
ecosystem components on the cluster, you can connect to that 
service at 
    https://[cluster_node_0]:9443

For more details on the template itself and customizing it to your
needs, please reference DEVELOPERS.txt in this repository.
<h2>
Command Line Usage
</h2>

The template deployment is supported via the Azure Command Line 
utility (available from 
http://azure.microsoft.com/en-us/documentation/articles/xplat-cli/#configure ).

After installing that utility and authenticating to the Azure
environment, you can take the following steps to deploy a cluster
from the command line :
<ol>
<li>
Clone the default parameters file (azuredeploy-parameters.json) 
</li>
<li>
Update the new parameter file, ap.json, with your desired settings
for clusterName and adminPassword
</li>
<li>
Launch a resource group and deploy the MapR software
<p>
azure group create "newgroup" "West US" -f azuredeploy.json -d MapRtest  -e ap.json
</p
</li>
</ol>

<h2>
Resource Naming Conventions
</h2>

The template creates new storage account resources for each node in 
the cluster.   Because the namespace for storage accounts is global
across Azure regions, you must be careful to specify a unique MapR
cluster name in order to avoid errors during the deployment.

