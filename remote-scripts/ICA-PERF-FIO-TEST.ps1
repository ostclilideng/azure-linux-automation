<#-------------Create Deployment Start------------------#>
Import-Module .\TestLibs\RDFELibs.psm1 -Force
$result = ""
$testResult = ""
$resultArr = @()
$isDeployed = DeployVMS -setupType $currentTestData.setupType -Distro $Distro -xmlConfig $xmlConfig
if ($isDeployed)
{
	try
	{
		$testVMData = $allVMData
		ProvisionVMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"
		LogMsg "Generating constansts.sh ..."
		$constantsFile = "$LogDir\constants.sh"
		Set-Content -Value "#Generated by Azure Automation." -Path $constantsFile
		foreach ( $param in $currentTestData.TestParameters.param)
		{
			Add-Content -Value "$param" -Path $constantsFile
			LogMsg "$param added to constants.sh"
			if ( $param -imatch "startThread" )
			{
				$startThread = [int]($param.Replace("startThread=",""))
			}
			if ( $param -imatch "maxThread" )
			{
				$maxThread = [int]($param.Replace("maxThread=",""))
			}
		}
		LogMsg "constanst.sh created successfully..."
		#endregion
		
		#region EXECUTE TEST
		$myString = @"
chmod +x perf_fio.sh
./perf_fio.sh &> fioConsoleLogs.txt
. azuremodules.sh
collect_VM_properties
"@

		$myString2 = @"
wget https://konkaciwestus1.blob.core.windows.net/scriptfiles/JSON.awk
wget https://konkaciwestus1.blob.core.windows.net/scriptfiles/gawk
wget https://konkaciwestus1.blob.core.windows.net/scriptfiles/fio_jason_parser.sh
chmod +x *.sh
cp fio_jason_parser.sh gawk JSON.awk /root/FIOLog/jsonLog/
cd /root/FIOLog/jsonLog/
./fio_jason_parser.sh
cp perf_fio.csv /root
chmod 666 /root/perf_fio.csv
"@
		Set-Content "$LogDir\StartFioTest.sh" $myString
		Set-Content "$LogDir\ParseFioTestLogs.sh" $myString2		
		RemoteCopy -uploadTo $testVMData.PublicIP -port $testVMData.SSHPort -files ".\$constantsFile,.\remote-scripts\azuremodules.sh,.\remote-scripts\perf_fio.sh,.\$LogDir\StartFioTest.sh,.\$LogDir\ParseFioTestLogs.sh" -username "root" -password $password -upload
		RemoteCopy -uploadTo $testVMData.PublicIP -port $testVMData.SSHPort -files $currentTestData.files -username "root" -password $password -upload
		$out = RunLinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -command "chmod +x *.sh" -runAsSudo
		$testJob = RunLinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -command "./StartFioTest.sh" -RunInBackground -runAsSudo

		#endregion

		#region MONITOR TEST
		while ( (Get-Job -Id $testJob).State -eq "Running" )
		{
			$currentStatus = RunLinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -command "tail -1 runlog.txt"-runAsSudo
			LogMsg "Current Test Staus : $currentStatus"
			WaitFor -seconds 20
		}

		$finalStatus = RunLinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -command "cat state.txt"
		RemoteCopy -downloadFrom $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "FIOTest-*.tar.gz"
		RemoteCopy -downloadFrom $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "VM_properties.csv"
		
		$testSummary = $null

		#endregion

		if ( $finalStatus -imatch "TestFailed")
		{
			LogErr "Test failed. Last known status : $currentStatus."
			$testResult = "FAIL"
		}
		elseif ( $finalStatus -imatch "TestAborted")
		{
			LogErr "Test Aborted. Last known status : $currentStatus."
			$testResult = "ABORTED"
		}
		elseif ( $finalStatus -imatch "TestCompleted")
		{
			$out = RunLinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -command "/root/ParseFioTestLogs.sh"
			RemoteCopy -downloadFrom $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "perf_fio.csv"
			LogMsg "Test Completed."
			$testResult = "PASS"
		}
		elseif ( $finalStatus -imatch "TestRunning")
		{
			LogMsg "Powershell backgroud job for test is completed but VM is reporting that test is still running. Please check $LogDir\zkConsoleLogs.txt"
			LogMsg "Contests of summary.log : $testSummary"
			$testResult = "PASS"
		}
		LogMsg "Test result : $testResult"
		LogMsg "Test Completed"
		$resultSummary +=  CreateResultSummary -testResult $testResult -metaData "" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
		
    try
        {
			foreach($line in (Get-Content "$LogDir\perf_fio.csv"))
			{
				if ( $line -imatch "Max IOPS of each mode" )
				{
					$maxIOPSforMode = $true
					$maxIOPSforBlockSize = $false
					$fioData = $false
				}
				if ( $line -imatch "Max IOPS of each BlockSize" )
				{
					$maxIOPSforMode = $false
					$maxIOPSforBlockSize = $true
					$fioData = $false
				}
				if ( $line -imatch "Iteration,TestType,BlockSize" )
				{
					$maxIOPSforMode = $false
					$maxIOPSforBlockSize = $false
					$fioData = $true
				}
				if ( $maxIOPSforMode )
				{
					Add-Content -Value $line -Path $LogDir\maxIOPSforMode.csv
				}
				if ( $maxIOPSforBlockSize )
				{
					Add-Content -Value $line -Path $LogDir\maxIOPSforBlockSize.csv
				}
				if ( $fioData )
				{
					Add-Content -Value $line -Path $LogDir\fioData.csv
				}
			}
			$maxIOPSforModeCsv = Import-Csv -Path $LogDir\maxIOPSforMode.csv
			$maxIOPSforBlockSizeCsv = Import-Csv -Path $LogDir\maxIOPSforBlockSize.csv
			$fioDataCsv = Import-Csv -Path $LogDir\fioData.csv


			LogMsg "Uploading the test results.."
			$dataSource = $xmlConfig.config.Azure.database.server
			$DBuser = $xmlConfig.config.Azure.database.user
			$DBpassword = $xmlConfig.config.Azure.database.password
			$database = $xmlConfig.config.Azure.database.dbname
			$dataTableName = $xmlConfig.config.Azure.database.dbtable
			$TestCaseName = $xmlConfig.config.Azure.database.testTag
			if ($dataSource -And $DBuser -And $DBpassword -And $database -And $dataTableName) 
			{
				$GuestDistro	= cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}
				if ( $UseAzureResourceManager )
				{
					$HostType	= "Azure-ARM"
				}
				else
				{
					$HostType	= "Azure"
				}
				
				$HostBy	= ($xmlConfig.config.Azure.General.Location).Replace('"','')
				$HostOS	= cat "$LogDir\VM_properties.csv" | Select-String "Host Version"| %{$_ -replace ",Host Version,",""}
				$GuestOSType	= "Linux"
				$GuestDistro	= cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}
				$GuestSize = $testVMData.InstanceSize
				$KernelVersion	= cat "$LogDir\VM_properties.csv" | Select-String "Kernel version"| %{$_ -replace ",Kernel version,",""}
				
				$connectionString = "Server=$dataSource;uid=$DBuser; pwd=$DBpassword;Database=$database;Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"
				
				$SQLQuery = "INSERT INTO $dataTableName (TestCaseName,TestDate,HostType,HostBy,HostOS,GuestOSType,GuestDistro,GuestSize,KernelVersion,BlockSize_KB,QDepth,seq_read_iops,seq_read_lat_usec,rand_read_iops,rand_read_lat_usec,seq_write_iops,seq_write_lat_usec,rand_write_iops,rand_write_lat_usec) VALUES "

				for ( $QDepth = $startThread; $QDepth -le $maxThread; $QDepth *= 2 ) 
				{
					$seq_read_iops = ($fioDataCsv |  where { $_.TestType -eq "read" -and  $_.Threads -eq "$QDepth"} | Select ReadIOPS).ReadIOPS
					$seq_read_lat_usec = ($fioDataCsv |  where { $_.TestType -eq "read" -and  $_.Threads -eq "$QDepth"} | Select MaxOfReadMeanLatency).MaxOfReadMeanLatency

					$rand_read_iops = ($fioDataCsv |  where { $_.TestType -eq "randread" -and  $_.Threads -eq "$QDepth"} | Select ReadIOPS).ReadIOPS
					$rand_read_lat_usec = ($fioDataCsv |  where { $_.TestType -eq "randread" -and  $_.Threads -eq "$QDepth"} | Select MaxOfReadMeanLatency).MaxOfReadMeanLatency
					
					$seq_write_iops = ($fioDataCsv |  where { $_.TestType -eq "write" -and  $_.Threads -eq "$QDepth"} | Select WriteIOPS).WriteIOPS
					$seq_write_lat_usec = ($fioDataCsv |  where { $_.TestType -eq "write" -and  $_.Threads -eq "$QDepth"} | Select MaxOfWriteMeanLatency).MaxOfWriteMeanLatency
					
					$rand_write_iops = ($fioDataCsv |  where { $_.TestType -eq "randwrite" -and  $_.Threads -eq "$QDepth"} | Select WriteIOPS).WriteIOPS
					$rand_write_lat_usec= ($fioDataCsv |  where { $_.TestType -eq "randwrite" -and  $_.Threads -eq "$QDepth"} | Select MaxOfWriteMeanLatency).MaxOfWriteMeanLatency

					$BlockSize_KB= (($fioDataCsv |  where { $_.Threads -eq "$QDepth"} | Select BlockSize)[0].BlockSize).Replace("K","")
                    
				    $SQLQuery += "('$TestCaseName','$(Get-Date -Format yyyy-MM-dd)','$HostType','$HostBy','$HostOS','$GuestOSType','$GuestDistro','$GuestSize','$KernelVersion','$BlockSize_KB','$QDepth','$seq_read_iops','$seq_read_lat_usec','$rand_read_iops','$rand_read_lat_usec','$seq_write_iops','$seq_write_lat_usec','$rand_write_iops','$rand_write_lat_usec'),"	
				    LogMsg "Collected performace data for $QDepth QDepth."
				}

				$SQLQuery = $SQLQuery.TrimEnd(',')
				Write-Host $SQLQuery
				$connection = New-Object System.Data.SqlClient.SqlConnection
				$connection.ConnectionString = $connectionString
				$connection.Open()

				$command = $connection.CreateCommand()
				$command.CommandText = $SQLQuery
				
				$result = $command.executenonquery()
				$connection.Close()
				LogMsg "Uploading the test results done!!"
			}
			else
			{
				LogMsg "Invalid database details. Failed to upload result to database!"
			}
		
		}
		catch 
		{
			$ErrorMessage =  $_.Exception.Message
			LogErr "EXCEPTION : $ErrorMessage"
		}
		

	}
	catch
	{
		$ErrorMessage =  $_.Exception.Message
		LogMsg "EXCEPTION : $ErrorMessage"   
	}
	Finally
	{
		$metaData = "NTTTCP RESULT"
		if (!$testResult)
		{
			$testResult = "Aborted"
		}
		$resultArr += $testResult
	}   
}

else
{
	$testResult = "Aborted"
	$resultArr += $testResult
}

$result = GetFinalResultHeader -resultarr $resultArr

#Clean up the setup
DoTestCleanUp -result $result -testName $currentTestData.testName -deployedServices $isDeployed -ResourceGroups $isDeployed

#Return the result and summery to the test suite script..
return $result, $resultSummary
