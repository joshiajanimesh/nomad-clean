Param
(
    [Parameter(
        Mandatory=$true,
        helpMessage = 'CM sitecode',		
        Position = 0)]
		[validateNotNullOrEmpty()]
		[validateLength(1,3)]
    [string]$sitecode,
    
    [Parameter(
        Mandatory=$true,
        helpMessage = 'task sequence pkgIDs seperated by commas',
        Position = 1)]
        [validateNotNullOrEmpty()]
    [string[]]$tsid, 

    [Parameter(
        Mandatory=$false,
        helpMessage = 'individual pkgIDs seperated by commas',
        Position = 2)]
        [validateNotNullOrEmpty()]
    [string[]]$pkgid,

    [Parameter(
        Mandatory=$true,
        helpMessage = 'Enter package source UNC path',        
        Position = 1)]
        [validateScript({            
            ([bool]([uri]$_).isUNC) -and ($_ -match '\\\\\w+\\\w+')            
        })]    
    [string]$pkgSrcPath,

    [Parameter(
        Mandatory=$false,
        helpMessage = 'generate unique package list only, will not create CM package',
        Position = 4)]
    [Switch]$listonly,
	
	[Parameter(
        Mandatory=$false,
        helpMessage = 'Ditribution point group name(s)',
        Position = 5)]
        [validateNotNullOrEmpty()]    
    [string[]]$dpGroupName,
	
	[Parameter(
        Mandatory=$false,
        helpMessage = 'Distribution point(s)',
        Position = 6)] 
        [validateNotNullOrEmpty()]   
    [string[]]$dpName 
 
)

function main
{

    try
    {
        <#
        load configurationManger module         
        $env:SMS_ADMIN_UI_PATH expands to C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin 
        module location is 1 folder level above
        use split-path -parent parameter for importing module
        #>
        write-host "Importing $modname module" -foregroundColor green        

        import-module (join-path -path $(split-path -path $cmconpath -parent -errorAction stop) -childPath $modname -errorAction stop)

        #set-location of $sitecode
        write-host "Setting site code location to '$sitecode'" -foregroundColor green

        set-location "$sitecode`:\" -errorAction stop 

        #take task sequence pkgID array and pass it to build a unique list of referenced packages in each 
        write-host "Processing task sequence IDs" -foregroundColor green 

        $tsid | `
        foreach-object `
        {
            (get-cmTaskSequence -taskSequencePackageID $_ -errorAction stop).references.package | `
            foreach-object `
            {
                if(!$pkgRef.contains($_)) 
                {
                    $pkgRef += $_
                } else {

                    #do nothing, duplicate pkgID 
                }
            }  
        }
        
        #take individual pkgID array and add it to $pkgref(duplicates will not be added)
        if($pkgid)
        {
            write-host "Processing individual package IDs" -foregroundColor green 

            $pkgid | where-object {$pkgRef -notContains $_} | `
            foreach-object `
            {
                $pkgRef += $_ 
            }    
        } 
        <#create package on SCCM content library only if 
        $pkgRef contains 1 or more items #>
        if($pkgRef.count) 
        {
            #Cast $pkgSrcPath
            $pkgSrcPath = "filesystem::$pkgSrcPath"

            #create package source directory
            write-host "Creating package source directory" -foregroundColor green 

            $pkgDir = new-item -type directory -Path $(join-path -path $pkgSrcPath `
            -childPath "ncache-clean-$(get-date -Format 'yyyyMMddHHmm')") -force -errorAction stop 
            $mstrFil = "filesystem::$pkgDir\pkglist.txt"
            write-host "`t$($pkgDir.fullname) created" -foregroundColor blue 

            #add master list to source directory
            write-host "Adding master list to package source directory" -foregroundColor green

            add-content -Path $mstrFil -Value $pkgRef -errorAction stop 

            #copy end-point cleanup script
            write-host "Copying endpoint script to package source directory" -foregroundColor green 

            copy-item -path "filesystem::$PSScriptRoot\endpoint-scripts\*.ps1" `
                -destination "filesystem::$pkgDir" -errorAction stop
            
            #create package
            write-host "Creating SCCM package" -foregroundColor green 
            
            $ncp = new-cmPackage -name "$Nomad Cache Clean-$(get-date -Format 'yyMMddHHmm')" `
                    -version "$(get-date -Format 'yyyyMMddHHmm')" -manufacturer "[OSD] - Tools" `
                    -language "English" -description "Master .TXT file listing pkgIDs to keep in nomad cache" `
                    -path $pkgDir.fullName -errorAction stop
            #create package program
            write-host "Creating package program(s)" -foregroundColor green 
            
            $prms = @{
                PackageName = "$($ncp.name)" 
                StandardProgramName = "basicClean" 
                CommandLine = "powershell.exe -executionPolicy bypass -file 'nomad-clean.ps1'" 
                RunType = "hidden" 
                ProgramRunType = "WhetherOrNotUserIsLoggedOn"
            }
            new-cmProgram @prms | out-null
            $prms = @{
                PackageName = "$($ncp.name)" 
                StandardProgramName = "deepClean" 
                CommandLine = "powershell.exe -executionPolicy bypass -file 'nomad-clean.ps1' -deepclean" 
                RunType = "hidden" 
                ProgramRunType = "WhetherOrNotUserIsLoggedOn"
            }
            new-cmProgram @prms | out-null                   
            
            if($dpGroupName.count) {
                write-host "Begin package distribution" -foregroundColor green 
                start-cmContentDistribution -packageID $ncp.packageID `
                -distributionPointGroupName $dpGroupName
            }  
            
            #can cause error if any DP is a member of DP group in prvious command
            #call with -errorAction silentlyContinue

            if($dpName.count) {
                write-host "Begin package distribution" -foregroundColor green 
                start-cmContentDistribution -packageID $ncp.packageID `
                -distributionPointName $dpName -errorAction silentlyContinue 
            }        
            write-host "Warning: $($ncp.name) - $($ncp.packageID) object path set to default" -foregroundColor yellow 
            write-host "Warning: $($ncp.name) - $($ncp.packageID) Nomad settings not configured" -foregroundColor yellow
        }
    }
    catch [System.IO.FileNotFoundException]
    {
        write-host "The specified module '$($error[0].targetObject)' was not loaded because `nno valid module file was found in any module directory." -foregroundColor red
    }
    catch [System.Management.Automation.DriveNotFoundException] 
    {
        write-host "A drive with the name '$($error[0].targetObject)' does not exist." -foregroundColor red
    }
    catch [System.Management.Automation.ParameterBindingException]
    {
        write-host "Unable to resolve environment variable: SMS_ADMIN_UI_PATH " -foregroundColor red
    }
    catch [System.Exception]
    {
        write-host "Exception caught: $($error[0].exception)" -foregroundColor red
    }
    finally
    {
        set-location $env:windir -errorAction stop         
    }

} #end function main

function validate-input {
}

    #global variables
        $CMPSSuppressFastNotUsedCheck = $true
        $cmconpath = $env:SMS_ADMIN_UI_PATH
        $modName = "configurationManager"
        $pkgRef = @()   
        write-host "$(Get-Date); <---- Starting $($MyInvocation.ScriptName) on host $env:COMPUTERNAME  ---->"

        main
        
        

    

     

