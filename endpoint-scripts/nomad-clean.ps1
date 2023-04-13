<# tasks to work on     
    -verify ccm logging
    -add logic for -mapreg parameter    
#>

<#
========================================================================
	Purpose:	Clean unwanted SCCM packages from Nomad and CCM cache
	
	Usage:		.\nomad-clean-<ver>.ps1 <Required Parameter> [Optional Parameter]
	
                [-deepclean]           [Specifies if deep clean is required, 
                                            i.e. remove/clean unwanted pkgIDs + .lsz files present 
                                            in nomad cache but not activated in registry]
                [-mapreg]              [Adds functionality to tattoo registry with data about deleted packages
                                        This will help maintain a historical view on:
                                            1.space recovered in Nomad and CCM cache- most recent recovered size will be overwritten
                                            2.a key for packages that were activated in Nomad registry
                                            3.a key for packages that were deep cleaned
                                            4.Both keys in 2. and 3. will have sub-keys denoting packageIDs
                                                4.a.sub-keys will have following key-values: package version, deletion status, deletion date
                                        Currently this is done through crating .json files for main and deep-clean modules]                
                [-logFile]             [Specifies the full path to the log file]
========================================================================
#>

Param
(
    [Parameter(
        Mandatory=$false,
        Position = 0)]
    [Switch]$deepclean,

    [Parameter(
        Mandatory=$false,
        Position=1)]
    [Switch]$mapreg,
    
    [Parameter(
		Mandatory = $false,
		ValueFromPipeline = $true,
		HelpMessage = 'Specifies the full path to the log file, e.g. "C:\Log\Logfile.log"',
		Position = 2)]
	[ValidateNotNullorEmpty()]
    [string]$logFile="$([environment]::GetEnvironmentVariable('TEMP', 'Machine'))" + "\nomadclean.log"	
)
        
function logandconsole($Message)
{
	try 
    {
		if (!$logInitialized) 
        {
			"{0}; <---- Starting {1} on host {2}  ---->" -f (Get-Date), $MyInvocation.ScriptName, $env:COMPUTERNAME | Out-File -FilePath $logFile -Append -Force
			"{0}; {1} version: {2}" -f (Get-Date), $script:MyInvocation.MyCommand.Name, $scriptVersion | Out-File -FilePath $logFile -Append -Force
			"{0}; Initialized logging at {1}" -f (Get-Date), $logFile | Out-File -FilePath $logFile -Append -Force
			
			$script:logInitialized = $true
		}
		
		foreach ($line in $Message) 
        {
			$line = "{0}; {1}" -f (Get-Date), $line
			$line | Out-File -FilePath $logFile -Append -Force
		}
		
#console logging switched off for SCCM version of script
        #Write-Host $Message
		
	} 
    catch [System.IO.DirectoryNotFoundException] 
    {
		$script:logFile = "$([environment]::GetEnvironmentVariable('TEMP', 'Machine'))" + "\nomadclean.log"	
		Write-Host "[Warning] Could not find a part of the path $logFile. The output would be redirected to console" 
		
	} 
    catch [System.UnauthorizedAccessException] 
    {
		$script:logFile = "$([environment]::GetEnvironmentVariable('TEMP', 'Machine'))" + "\nomadclean.log"	
		Write-Host "[Warning] Access to the path $logFile is denied. The output would be redirected to console"
		
	} 
    catch [system.exception] 
    {
		Write-Host  "[Error] Exception calling 'LogAndConsole':" $_.Exception.Message
		
        #$tsEnv.value("APErrorCode") = $MyInvocation.ScriptLineNumber
        exit 1
	}
} #end function logandconsole

function set-prereqs 
{ 
    <# 
    .SYNOPSIS 
        accepts a single executable name and array of arguments to be supplied 
        calls start-process command that spawns a process and returns a process object
    .PARAMETER  
        $execObj string param specifying name of executable 
        $argList string array specifying arguments for the executable
    .EXAMPLE 
        set-prereqs -execObj "dism.exe" -argList " /online"," /enable-feature:RemoteServerAdministrationTools"
    #> 
    [cmdletBinding()]
    [outputType([object])] 
    param 
    ( 
        [Parameter(Mandatory=$true,
        valueFromPipeline=$true,
        valueFromPipelineByPropertyName=$true,
        position=0)]         
        [string]$execObj,

        [Parameter(Mandatory=$false,
        valueFromPipeline=$true,
        valueFromPipelineByPropertyName=$true,
        position=1)]
        [string[]]$argList= " /?" 
    ) 
     try 
     {    
        #var for process object returned by the function
        $procObj = $null                       
        switch($execObj.toLower()) 
        {
            "cachecleaner.exe" 
            {                            
                $procObj = start-process -FilePath $execObj -ArgumentList $argList -passThru -wait -windowStyle hidden
            }
            default 
            {
                logandconsole "Executable: $($execObj)"  
                logandconsole "Argument list: $($argList)" 
                logandconsole "assign non-zero to APErrorCode to fail TS"  

                #$tsEnv.value("APErrorCode") = 0604
                exit 1
            }
        }
        #return process object
        $procObj                 
     }
        catch [system.exception] 
        {
            logandconsole "Exception caught: $($error[0].exception)"  
            logandconsole "$($PSItem.scriptStackTrace)" 
            logandconsole "assign non-zero to APErrorCode to fail TS"  

            #$tsEnv.value("APErrorCode") = 0604
            exit 1         
        }
} #end function set-prereqs

function get-procexec 
{ 
    <# 
    .SYNOPSIS 
        monitors execution state/outcome of a process
        returns a boolean $true/$false 
        starts a do-while script block until process has exited with exitCode = 0
        if process execution is greater than a given time threshold, do-while script block is exited, process is not terminated
    .PARAMETER  
        $procObj: object returned by start-process cmdlet 
    .EXAMPLE 
        get-procexec -procObj $procObjMain -maxTimeSec <seconds>
    #> 
    [cmdletBinding()]
    [outputType([boolean])] 
    param 
    ( 
        [Parameter(Mandatory=$true,
        valueFromPipeline=$true,
        valueFromPipelineByPropertyName=$true,
        position=0)]         
        [object]$procObj,
        
        [Parameter(Mandatory=$true,
        valueFromPipeline=$true,
        valueFromPipelineByPropertyName=$true,
        position=0)]
        [int]$maxTimeSec        
    ) 
        try 
        {
            #stopwatch to calculate script running time
            $sWatch = [system.diagnostics.stopwatch]::startNew()

            #boolean var for decision making
            $proceed = $true
            do 
            {
                #exit if process execution takes longer than $maxTime minutes
                if($sWatch.elapsed.totalseconds -gt $maxTimeSec) 
                {
                    logandconsole "Process ID: $($procObj.id) has been running for $($sWatch.elapsed.totalseconds), exiting process execution" 
                    logandconsole "Process ID: $($procObj.id) exit status:$($procObj.hasexited), exiting process execution" 
                    logandconsole "Process ID: $($procObj.id) exit code:$($procObj.exitcode) , exiting process execution" 

                    $proceed = $false
                    break 
                } 
                else 
                {
                    #do nothing 
                }
            } until(($procObj.hasexited))            
        }
        catch [system.exception] 
        {
            logandconsole "Exception caught: $($error[0].exception)"  
            logandconsole "$($PSItem.scriptStackTrace)" 
            logandconsole "assign non-zero to APErrorCode to fail TS"  

            #$tsEnv.value("APErrorCode") = 0604
            exit 1        
        }
        #return boolean object for script continuation        
        $proceed        
} #end function get-procexec

function get-stats
{
    Param
    (
        [Parameter(
        Mandatory=$true,
        Position = 0)]
        [String]$locn 
    )
    try 
    {
        [MATH]::round(((Get-ChildItem "$locn" -Recurse | `
            Measure-Object -Property Length -Sum -ErrorAction Stop).Sum / 1MB),2)
    }
    catch [system.exception] 
    {
        logandconsole "Exception caught: $($error[0].exception)"  
        logandconsole "$($PSItem.scriptStackTrace)" 
        logandconsole "assign non-zero to APErrorCode to fail TS"  

        #$tsEnv.value("APErrorCode") = 0604
        exit 1       
    }    
} #end function get-stats

function verify-ccm 
{
    Param
    (
        [Parameter(
        mandatory=$true,
        position=0)]
        [string]$pkgid,

        [Parameter(
        mandatory=$false,
        position=1)]
        [string]$pkgver,

        [Parameter(
        mandatory=$true,
        position=2)]
        [Object]$ocom,

        [Parameter(
        mandatory=$false,
        position=3)]
        [switch]$purge
    )
    try 
    {        
        $chElObj = $ocom.getCacheInfo().getCacheElements() | `
            where-object {$_.contentID -eq $pkgid}
        
        <# 
        function is called without $purge when -pkgver parameter of cacheCleaner.exe in main is
        supplied with a version number. This should delete content from CCM cache.
        Verify, if still present, delete
        #>
        if(!$purge.isPresent)  
        {
            $chElObj | where-object {$_.contentVersion -eq $pkgver} | `
                foreach-object `
                {
                    logandconsole "warning: cacheCleaner.exe was unable to clear $pkgid from CCM cache"            
                    logandconsole "deleting $pkgid from $($ocom.getCacheInfo().location)"

                    $ocom.getCacheInfo().deleteCacheElement($_.cacheElementID)     
                }
            <# 
            cachecleaner.exe will only remove content from CCM cache for which -pkgver matches contentVersion property 
            it is very likely CCM cache might still have content pertaining to other versions the same package ID. 
            In that case, run $ocom object method to delete from CCM cache  
            #>
            $chElObj = $ocom.getCacheInfo().getCacheElements() | `
            where-object {$_.contentID -eq $pkgid}
            if($chELObj.contentVersion.count) 
            {
                logandconsole "$($chElObj.contentversion.count) instances of $pkgid present in CCM cache associated with other content version(s), deleting..."

                $chElObj.cacheElementID | `
                    foreach-object `
                    {
                        $ocom.getCacheInfo().deleteCacheElement($_)     
                    }                    
            }    
        } 
        elseif($purge.isPresent) 
        {
                <# when cacheCleaner.exe is run with pkgver parameter set to version activated in registry
                packageID is cleared from CCM cache. Alternatively when pkgver parameter is supplied
                an asterix '*", it does not purge from CCM cache #>
                logandconsole "Function called with purge parameter, removing $pkgid from CCM cache"
                logandconsole "deleting $pkgid from $($ocom.getCacheInfo().location), if present"
                
                $chElObj.cacheElementID | `
                    foreach-object `
                    {
                        $ocom.getCacheInfo().deleteCacheElement($_)     
                    } 
        }
    }
    catch [sytem.exception] 
    {
        logandconsole "Exception caught: $($error[0].exception)"  
        logandconsole "$($PSItem.scriptStackTrace)" 
        logandconsole "assign non-zero to APErrorCode to fail TS"  

        #$tsEnv.value("APErrorCode") = 0604
        exit 1    
    }
} #end function verify-ccm 

function deep-clean 
{
        <#
            Some package IDs and its one or more associated .LSZ file(s) might be present on the HDD only
            (not activated in the registry at all) after cacheCleaner has been run in the previous section

                1.Get all packages on HDD in Nomad cache(after clearing from registry in main module) location $nmHDDPath to $ephdd
                2.The difference between $tsref and $ephdd will give unwanted package IDs that were 
                    not activated in the registry and shouldn't be present on the system
                3.locate all(there could be more than 1) associated .LSZ files on the HDD for packages identified in point 2 
        #>
            try 
            {
                $ephdd = @()
                $ht = @{}
                $rxp = '\d[^_]+$'
                (get-childItem "$nmHDDPath\*cache" `
                    -attributes directory).name | ` 
                        forEach-object `
                        {
                            $ephdd += $_.substring(0,$_.length-6)
                        }
                logandconsole "A total of $($ephdd.count) items remain activated in $nmHDDPath"
                logandconsole "Building list of package IDs not activated in $nmRegPath and not required in Nomad cache path $nmHDDPath"
                         
                $ephdd | where-object {$tsref -notcontains $_} |  `
                foreach-object `
                {
                    #initialise hash-table for each pkgID as the key to add .LSZ file versions in an array
                    if(!$ht.containsKey($_))
                    {
                        $ht.add($_,@())
                    }
                        <#if one or more .lsz files exist for a pkgID, collect all file names to an array.
                        loop through each file name to extract .lsz version through regex pattten matching #>
                        $fname = @()
                        $fname += (get-childItem "$nmHDDPath\$_*lsz").name
                        foreach($fn in $fname) 
                        {
                            if($fn -match $rxp)
                            {
                                $ht.$($_) += $matches[0].toLower().replace('.lsz','')                                  
                            }
                            #unwanted pkgID cache folder exists by itself, it has no .LSZ file(s)
                            else 
                            {
                                $ht.$($_) += $null 
                            }          
                        }                      
                }
                logandconsole "A total of $($ht.count) non-required items present on $nmHDDPath"
                              
            }  
            catch [system.exception] 
            {
                logandconsole "Exception caught: $($error[0].exception)"  
                logandconsole "$($PSItem.scriptStackTrace)" 
                logandconsole "assign non-zero to APErrorCode to fail TS"  

                #$tsEnv.value("APErrorCode") = 0604
                exit 1    
            }
        <#
            1.Iterate $ht hash table
            2.run cacheCleaner.exe -deletepkg=<pkgID> -pkgver=* for $ht keys that have one or more .LSZ file versions or none
            3.Running command: cacheCleaner.exe -deletepkg=$($_) -pkgver=*" should remove the package ID folder from $nmHDDPath but will not clear from CCM cache. 
            4.Call verify-ccm with -purge to clear from CCM cache 
        #>
            if($ht.count)
            {
                try 
                {
                    logandconsole "Calling $execObj with -deletepkg parameter, -pkgver will be assigned a wild-card"

                        $ht.keys | `
                        foreach-object `  
                        {
                            $procObj = set-prereqs -execObj $execObj -argList "-deletepkg=$($_)","-pkgver=*"
                            if(!(get-procexec -procObj $procObj -maxTimeSec $maxTimeSec)) 
                            {
                                #log for which pkgid cachecleaner.exe takes longer than $maxTimeSec seconds, move on to the next pkgid, don't exit script
                                logandconsole "cachecleaner.exe took longer than $maxTimeSec seconds for $_ , continuing..."

                            }
                            else 
                            {
                                #call verify-ccm with -purge to remove pkgid from CCM cache
                                verify-ccm -pkgid $_ -ocom $ocom -purge 
                            
                                <#cachecleaner.exe and verify-ccm have run without error at this point
                                verify no .lsz files have been left behind#>
                                (get-childItem -path "$nmHDDPath\$_*lsz").fullName | `
                                    foreach-object `
                                    {
                                        if($_) 
                                        {
                                            remove-item $_  
                                        }
                                    }   
                            }    
                        } #end foreach-object
                }
                catch [system.exception] 
                {
                    logandconsole "Exception caught: $($error[0].exception)"  
                    logandconsole "$($PSItem.scriptStackTrace)" 
                    logandconsole "assign non-zero to APErrorCode to fail TS"  

                    #$tsEnv.value("APErrorCode") = 0604
                    exit 1    
                }
                finally 
                {
                    logandconsole "Creating $($clnxtn) for deep-clean module"

                    $ht.GetEnumerator() | select-object -property key,value | `
                        convertTo-json -depth 3 | `
                        out-File -FilePath "$env:windir\temp\$dpcln$(get-date -format $dtfrmt)$clnxtn" -Append -Force
                }
            }
} #end function deep-clean  

function main 
{        
            try 
            {
                #Enumerate packageIDs from master file 
                #Mandatory file is locally available on the end point in the script directory
                $tsref = @()
                $tsref = get-content -path "$PSScriptRoot\pkglist.txt" -errorAction stop

                #query list of packages prestaged in Nomad cache and activated in registry of a given end-point
                $epreg = @()
                get-childItem $nmRegPath -errorAction stop | `
                    foreach-object `
                    {
                        $epreg += split-path -Path $_.name -leaf
                    }
               
                #query list of packages present in nomad cache
                $ephdd = @()
                (get-childItem "$nmHDDPath\*cache" `
                    -attributes directory).name | ` 
                        forEach-object `
                        {
                            $ephdd += $_.substring(0,$_.length-6)
                        }
                # if $tsref or $epreg count is zero, no need to run code below
                if($tsref.count -eq 0 -or $epreg.count -eq 0)
                {
                    logandconsole "No items present in master package file or activated in registry"
                }
                else 
                {       
                        <# 
                        1.Get list of unwanted package IDs by doing a difference between
                            $tsref and $epreg arrays
                        2.Pass the difference array to query 'version' property of each package ID registry key
                        3.Pass unwanted packageID and associated 'version' to cacheCleaner.exe -deletepkg=$($_) -pkgver=<version>"
                            this will remove package from Nomad cache($nmHDDPath) and CCM cache
                        4.Call verify-ccm to ensure package content is deleted from CCM cache(verify-ccm has logic to remove if it hasn't)
                        5.Build $epxtr hash-table to include each difference package ID as key and another hash-table including pkgver
                            and delete status(boolean), for eg. 
                            $epxtr = {
                                      'pkg1': {pkgver:7,dstat:$true},
                                      'pkg2': {pkgver:3,dstat:$true},
                                      'pkg3': {pkgver:1,dstat:$false}
                                     }
                        #>  
                        logandconsole "A total of $($epreg.count) items activated in $nmRegPath"
                        logandconsole "A total of $($ephdd.count) items present in $nmHDDPath"
                        logandconsole "Building list of package IDs activated in $nmRegPath but not required in Nomad cache path $nmHDDPath"
                        logandconsole "Calling $execObj with -deletepkg and -pkgver parameters"

                        $epxtr = @{}
                        $epreg | where-object {$tsref -notcontains $_} |  `
                        foreach-object `
                        {   
                            
                            $pkver = $((get-itemProperty -path $nmRegPath\$_ -errorAction silentlyContinue).version)                
                                
                            if(!$pkver)
                            {
                                logandconsole "version property for $nmRegPath\$($_) not found, -pkgver will be assigned a wild-card"
                                    
                                $pkver = "*"
                            }
                                                      
                            $procObj = set-prereqs -execObj $execObj -argList "-deletepkg=$($_)","-pkgver=$pkver"
                            if(!(get-procexec -procObj $procObj -maxTimeSec $maxTimeSec)) 
                            {
                                #log for which pkgid cachecleaner.exe takes longer than $maxTimeSec seconds, move on to the next pkgid, don't exit script
                                logandconsole "cachecleaner.exe took longer than $maxTimeSec seconds for $_ , continuing..."
                                  
                                #add extra activated package version and set deletion status to $false 
                                if(!$epxtr.containsKey($_))
                                {
                                    $epxtr.add($_,@{'pkgver'=$pkver; dstat=$false}) 
                                }        
                            }
                            else 
                            {
                                verify-ccm -pkgid $_ -pkgver $pkver -ocom $ocom

                                <#cachecleaner.exe and verify-ccm have run without error at this point
                                verify no .lsz files have been left behind#>
                                (get-childItem -path "$nmHDDPath\$_*lsz").fullName | `
                                    foreach-object `
                                    {
                                        if($_) 
                                        {
                                           remove-item $_  
                                        }
                                    }
                                #add every extra activated package version and set deletion status to $true 
                                if(!$epxtr.containsKey($_))
                                {
                                    $epxtr.add($_,@{'pkgver'=$pkver; dstat=$true}) 
                                }                   
                            }
                            
                        }
                        logandconsole "A total of $(($epxtr.keys | where-object {$epxtr.$_.dstat}).count) activated and unwanted packages cleaned from $nmRegPath and $($ocom.getCacheInfo().location)"
                        if($(($epxtr.keys | where-object {!$epxtr.$_.dstat}).count)) 
                        {
                            logandconsole "warning: Unable to clean:$(($epxtr.keys | where-object {!$epxtr.$_.dstat}).count) activated and unwanted packages from $nmRegPath and $($ocom.getCacheInfo().location)"    
                        }
                        
                    
                        #call deep-clean if the script is invoked with switch parameter deepclean 
                        if($deepclean.isPresent) 
                        {
                            logandconsole "$($myInvocation.scriptName) called with deepclean parameter, performing deep clean"
                            deep-clean 
                        }
                        #send in full h/w inventory
                        logandconsole "Sending full h/w inventory"

                        Get-WmiObject -ComputerName 'localhost' -Namespace `
                            'Root\CCM\INVAGT' -Class 'InventoryActionStatus' -Filter `
                            "InventoryActionID='{00000000-0000-0000-0000-000000000001}'" | `
                            Remove-WmiObject -ErrorAction stop 
                        Invoke-WMIMethod -ComputerName 'localhost' -Namespace `
                            'root\ccm' -Class 'SMS_CLIENT' -Name `
                            TriggerSchedule "{00000000-0000-0000-0000-000000000001}" `
                            -ErrorAction stop | out-null               
                } 
            }
                <#potential errors to catch: 
                    Master package list file inaccessbile/unavailable
                    Error enumerating prestaged package registry keys
                    error running cachecleaner.exe
                #>
            catch [system.exception] 
            {
                logandconsole "Exception caught: $($error[0].exception)"  
                logandconsole "$($PSItem.scriptStackTrace)" 
                logandconsole "assign non-zero to APErrorCode to fail TS"  

                #$tsEnv.value("APErrorCode") = 0604
                exit 1     
            }    
            finally 
            {
                if($epxtr.count)
                {
                    logandconsole "Creating $($clnxtn) for main module"

                    $epxtr.GetEnumerator() | select-object -property key,value | `
                        convertTo-json -depth 3 | `
                        out-File -FilePath "$env:windir\temp\$pkgcln$(get-date -format $dtfrmt)$clnxtn" -Append -Force
                }               
            }               
} #end function main       

    # global variables
            $nmRegPath = "hklm:\software\1E\nomadBranch\pkgStatus"
            $nmHDDPath = "$env:ProgramData\1E\nomadBranch"
            $execObj = "cachecleaner.exe" 
            $ocom = new-object -comobject "uiResource.uiResourceMgr"
            $maxTimeSec = 10
            $pkgcln = "pkgcln"
            $dpcln = "dpcln"
            $dtfrmt = "yyMMddHHmm"
            $clnxtn = ".json" 

            logandconsole "Nomad cache size:$(get-stats -locn $nmHDDPath\*cache) MB"
            logandconsole "CCM cache size:$(get-stats -locn $ocom.getCacheInfo().location) MB"

            main 
            logandconsole "Nomad cache size:$(get-stats -locn $nmHDDPath) MB"
            logandconsole "CCM cache size:$(get-stats -locn $ocom.getCacheInfo().location) MB"
          