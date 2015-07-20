# Advanced Linux Template : Deploy a Multi VM MapR Cluster

<a href="https://azuredeploy.net/" target="_blank">
    <img src="http://azuredeploy.net/deploybutton.png"/>
</a>


<h1>
ALPHA RELEASE
</h1>

This advanced template creates a Multi VM MapR Cluster, complete with 
MapR Community Edition licensing.   Users can select which instance
types to use; storage for each node is currently defined in the
template itself (4 1TB volumes per node).

The Control System interface to the cluster will be available at
	https://[cluster_node_0]:8443

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
azure group create "newgroup" "West US" 
-f azuredeploy.json -d MapRtest  -e ap.json
</li>
</ol>

