<#
Copyright 2021 Google LLC
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
     https://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
#>

# Version 1.0

$vmObjectList = @()
$vmTagsList = @()
$vmDisksList = @()
$vmPerfData = @()

$subList = Get-AzSubscription
$outputPath = "$(Get-Location)\output\"
$LogFile = "$outputPath\stratozone-azure-export.log"


function LogMessage
{
    param(
		[Parameter(Mandatory = $true)]
		[string]$Message
	)
	try{
    	Add-content $LogFile -value ((Get-Date).ToString() + " - " + $Message)
	}
	catch{
		Write-Host "Unable to Write to log file"
	}
}

try{
	if (!(Test-Path $outputPath)){
		New-Item -itemType Directory -Path $outputPath 
	}
	else{
		Remove-Item "$(Get-Location)\*.zip"
		Remove-Item "$outputPath\*.csv"
	}
}
catch{
		Write-Host "Error creating output directory" -ForegroundColor yellow
}


LogMessage("Starting collection script")

foreach ($sub in $subList){
	LogMessage("Processing Subscription $sub.Name")

	Select-AzSubscription -SubscriptionId $sub.Id
	Set-AzContext -SubscriptionId $sub.Id

	$vmCount = 0
	$rgCount = 0
	$vmStatusInfo = $null
	$vmSizeInfo = $null

	$rgList = Get-AzResourceGroup 

	foreach($rg in $rgList){
		$rgCount = $rgCount +1

		LogMessage("Processing Resource Group $($rg.ResourceGroupName)")

		$vmList = Get-AzVM -ResourceGroupName $rg.ResourceGroupName -Status -erroraction 'silentlycontinue'
		
		LogMessage("VM Count  $($vmList.Length)")
		Write-Progress -Activity "Data Collection" -Status "Collecting Resource Group $rgCount of $($rgList.Length)"

		foreach($vm in $vmList){
			#Write-Host $vm.Name
			try{
				$vmSizeInfo = Get-AzVMSize -VMName $vm.Name -ResourceGroupName $vm.ResourceGroupName | where{$_.Name -eq $vm.HardwareProfile.VmSize} -erroraction 'silentlycontinue'
			}
			catch{
				Write-Host "Error vmSizeInfo" -ForegroundColor yellow
			}

			try{
				$vmStatusInfo = Get-AzVM -Name $vm.Name -ResourceGroupName $vm.ResourceGroupName -Status -erroraction 'silentlycontinue'
			}
			catch{
				Write-Host "Error vmStatusInfo" -ForegroundColor yellow
			}

			#Collect IP information
			$primaryIp = ""
			$ipList = ""
			$piptxt = ""

			foreach($nic in $vm.NetworkProfile.NetworkInterfaces){
				$nicConfig = Get-AzResource -ResourceId $nic.Id | Get-AzNetworkInterface
				foreach($ipConfig in $nicConfig.IpConfigurations){
					foreach($pip in $ipConfig.PublicIpAddress){
						$pubIp = Get-AzResource -ResourceId $pip.id | Get-AzPublicIpAddress
						$piptxt = $pubIp.IpAddress 
					}
					$ipList = $ipList + $ipConfig.PrivateIpAddress + ";"
					if ($primaryIp -eq ""){
						$primaryIp = $ipConfig.PrivateIpAddress
					}
				}
			}
			if($ipList.Length -gt 1){
				$ipList = $ipList.Substring(0,$ipList.Length -1)
			}
		
			$vmBasicInfo = [pscustomobject]@{
				"VmId"=$vm.VmId
				"Name"=$vm.Name
				"PrimaryIP"=$primaryIp
				"PublicIP"=$piptxt
				"IpList"=$ipList
				"TotalDiskAllocated(GB)"=""
				"TotalDiskUsed(GB)"=""
				"Size"=$vm.HardwareProfile.VmSize
				"ProcessorNo"=$vmSizeInfo.NumberOfCores
				"Memory"=$vmSizeInfo.MemoryInMb
				"Location"=$vm.Location
				"OsType"=$vm.StorageProfile.osDisk.OsType
				"Publisher"=$vm.StorageProfile.ImageReference.Publisher
				"OsName"=$vm.StorageProfile.ImageReference.Offer
				"OsVersion"=$vm.StorageProfile.ImageReference.Sku
				"Status"=$vmStatusInfo.Statuses[1].DisplayStatus
				"ProvisioningState"=$vmStatusInfo.Statuses[0].DisplayStatus
				"CreateDate"=$vmStatusInfo.Statuses[0].Time
				"IsPhysical"="0"

			}
			$vmObjectList += $vmBasicInfo

			#collect all tags assigned to VM
			foreach($key in $vm.Tags.Keys){
				$vmTags = [pscustomobject]@{
					"VmId"=$vm.VmId
					"Key"= $key
					"Value"= $vm.Tags[$key]		
				}
				$vmTagsList += $vmTags
			}

			#collect info on all disks attached tot he VM
			foreach($disk in $vm.StorageProfile.DataDisks){
				$vmDataDisk = [pscustomobject]@{
					"VmId"=$vm.VmId
					"DiskName"=$disk.Name
					"Size"=$disk.DiskSizeGB
					"Used"="0"
					"StorageType"=$disk.ManagedDisk.StorageAccountType
				}
				$vmDisksList += $vmDataDisk
			}
			
			#Add OS disk to the list of disks for VM
			$vmOsDisk = [pscustomobject]@{
				"VmId"=$vm.VmId
				"DiskName"=$vm.StorageProfile.OSDisk.Name
				"Size"=$vm.StorageProfile.OSDisk.DiskSizeGB
				"Used"="0"
				"StorageType"=$vm.StorageProfile.OSDisk.ManagedDisk.StorageAccountType
			}
			$vmDisksList += $vmOsDisk

			$endTime = Get-Date
			$startTime = $endTime.AddDays(-30)

			#"Percentage CPU,Available Memory Bytes,Network Out Total"
			$vmCpuMatrics = Get-AzMetric -ResourceId $vm.Id -MetricName "Percentage CPU" -EndTime $endTime -StartTime  $startTime -TimeGrain 1:00:00 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
			$vmMemMatrics = Get-AzMetric -ResourceId $vm.Id -MetricName "Available Memory Bytes" -EndTime $endTime -StartTime  $startTime -TimeGrain 1:00:00 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
			$vmDiskRead = Get-AzMetric -ResourceId $vm.Id -MetricName "Disk Read Operations/Sec" -EndTime $endTime -StartTime  $startTime -TimeGrain 1:00:00 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
			$vmDiskWrite = Get-AzMetric -ResourceId $vm.Id -MetricName "Disk Write Operations/Sec" -EndTime $endTime -StartTime  $startTime -TimeGrain 1:00:00 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
			$vmNetOut = Get-AzMetric -ResourceId $vm.Id -MetricName "Network Out Total" -EndTime $endTime -StartTime  $startTime -TimeGrain 1:00:00 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
			$vmNetIn = Get-AzMetric -ResourceId $vm.Id -MetricName "Network In Total" -EndTime $endTime -StartTime  $startTime -TimeGrain 1:00:00 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

			for($i =0;$i -lt $vmCpuMatrics.Data.Count; $i++){
				try{
					$vmPerfMetrics = [pscustomobject]@{
						"VmId"=$vm.VmId
						"TimeStamp"=$vmCpuMatrics.Data[$i].TimeStamp
						"CpuPercent"=$vmCpuMatrics.Data[$i].Average
						"AvailableMemory"=$vmMemMatrics.Data[$i].Average
						"DiskReadOperations"=$vmDiskRead.Data[$i].Average
						"DiskWriteOperations"=$vmDiskWrite.Data[$i].Average
						"NetworkOut"=$vmNetOut.Data[$i].Total
						"NetworkIn"=$vmNetIn.Data[$i].Total
					}
				}
				catch{
						LogMessage($_.Exception.Message)
				}
				
				$vmPerfData += $vmPerfMetrics
			}
				
			$vmCount = $vmCount + 1
		}
	}
}

Write-Host "VM Count: " $vmCount
LogMessage("VM Count: $vmCount")

if($vmCount -gt 0){
	try{
		LogMessage("Write data to files")
		Write-Progress -Activity "Data Collection" -Status "Write to output files"

		$vmObjectList | Export-Csv -NoTypeInformation -Path "$outputPath\vmInfo.csv"
		$vmTagsList | Export-Csv -NoTypeInformation -Path "$outputPath\tagInfo.csv"
		$vmDisksList | Export-Csv -NoTypeInformation -Path "$outputPath\diskInfo.csv"
		$vmPerfData | Export-Csv -NoTypeInformation -Path "$outputPath\perfInfo.csv"
	}
	catch{
		Write-Host "Error writing output files" -ForegroundColor yellow
	}

	try{
		LogMessage("Compressing output files")
		Compress-Archive -Path "$outputPath\*.csv" -DestinationPath "$(Get-Location)\azure-import-files.zip"
	}
	catch{
		Write-Host "Error compressing output files" -ForegroundColor yellow
	}
}

Write-Host "Collection Completed"
LogMessage("Collection Completed")