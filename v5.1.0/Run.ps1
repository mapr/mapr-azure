Import-Module 'C:\Program Files (x86)\Microsoft SDKs\Azure\PowerShell\ServiceManagement\Azure\Azure.psd1'
Import-Module 'C:\Program Files (x86)\Microsoft SDKs\Azure\PowerShell\ResourceManager\AzureResourceManager\AzureResourceManager.psd1'

Clear-Host

Get-Date -Format "yyyy-MM-dd HH:mm:ss"

Switch-AzureMode AzureServiceManagement

$resourceGroupName = "<Add Resource Group Name>"
$location = "West US"
$storageAccountName = "<Add Storage Account Name>"
$containerName = "<Add existing container name>"
$storageAccountKey = (Get-AzureStorageKey -StorageAccountName $storageAccountName).Primary
$ctx = New-AzureStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey

Write-Host "Uploading files"
Set-AzureStorageBlobContent -File "azuredeploy.json" -Container $containerName -Context $ctx -Force
Set-AzureStorageBlobContent -File "azuredeploy-parameters.json" -Container $containerName -Context $ctx -Force
Set-AzureStorageBlobContent -File "network.json" -Container "arm" -Context $ctx -Force
Set-AzureStorageBlobContent -File "standard_lrs_storage.json" -Container $containerName -Context $ctx -Force
Set-AzureStorageBlobContent -File "premium_lrs_storage.json" -Container $containerName -Context $ctx -Force
Set-AzureStorageBlobContent -File "Standard_D3.json" -Container $containerName -Context $ctx -Force
Set-AzureStorageBlobContent -File "Standard_D4.json" -Container $containerName -Context $ctx -Force
Set-AzureStorageBlobContent -File "Standard_D12.json" -Container $containerName -Context $ctx -Force
Set-AzureStorageBlobContent -File "Standard_D13.json" -Container $containerName -Context $ctx -Force
Set-AzureStorageBlobContent -File "Standard_D14.json" -Container $containerName -Context $ctx -Force
Set-AzureStorageBlobContent -File "Standard_DS3.json" -Container $containerName -Context $ctx -Force
Set-AzureStorageBlobContent -File "Standard_DS4.json" -Container $containerName -Context $ctx -Force
Set-AzureStorageBlobContent -File "Standard_DS12.json" -Container $containerName -Context $ctx -Force
Set-AzureStorageBlobContent -File "Standard_DS13.json" -Container $containerName -Context $ctx -Force
Set-AzureStorageBlobContent -File "Standard_DS14.json" -Container $containerName -Context $ctx -Force

Switch-AzureMode AzureResourceManager

Get-Date -Format "yyyy-MM-dd HH:mm:ss"
	
Write-Host "Removing existing resource group"
Remove-AzureResourceGroup -Name $resourceGroupName -Force

Get-Date -Format "yyyy-MM-dd HH:mm:ss"
	
Write-Host "Submiting new deployment"
New-AzureResourceGroup -Name $resourceGroupName -Location $location -DeploymentName $resourceGroupName -TemplateParameterFile "azuredeploy-parameters.json" -TemplateFile "https://$storageAccountName.blob.core.windows.net/$containerName/azuredeploy.json" -Force

Get-Date -Format "yyyy-MM-dd HH:mm:ss"