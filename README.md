# nomad-clean
Remove pre-staged content from Nomad and CCM cache no longer required

# Background
SOE content is usually pre-staged to every production device before execution. 
Nomad has a built-in mechanism to update content, version information, CCM cache, Nomad registry data, and other background information of packages referenced in a given pre-stage task sequence. 
It makes no attempt to clean/remove packages that were pre-staged previously but no longer included in a pre-stage task sequence. 
As a result, unwanted package content remains activated in registry and takes space on local hard drive. This has a snow ball effect of claiming valuable hard drive space because the same package content is present in both Nomad and CCM cache. This can result in .MIF files larger than 5MB consequently prohibiting managed endpoints to send inventory data. 

# Solution 
Nomad ships with a built-in utility- cacheCleaner.exe which can be utilised to clean unwanted packages from both Nomad and CCM cache. The utility accepts a package ID and version(should match registry key value) as parameters. The solution is designed to generate a master list of required packages and remove unwanted content. 

# Components: 
# # Setup Script: create-master.PS1 
Designated to run on a PC with SCCM console locally installed or on an SCCM primary server. It accepts task sequence and individual package IDs as arguments and builds a unique list of referenced packages. The script then proceeds to create an SCCM package which contains the master package list and a clean-up script. The naming convention of this package is Nomad Cache Clean-yyMMddHHmm. 

# # Master Package List: pkglist.txt
The setup script creates a .TXT listing of package IDs which are required to be present in Nomad and CCM cache on each end-point. 

# # Clean-up Script: nomad-clean.PS1
Included with master package list SCCM package. This is the script that will run on each end-point to clean unwanted packages from Nomad cache registry, and hard drive locations as well as CCM cache. It will do a difference of package IDs present in the master file and Nomad cache, then proceed to remove unwanted packages.  It is designed to address the following edge cases: 
	1. Remove unwanted packages activated in Nomad registry and cache (basic clean)
	2. Remove unwanted packages not activated in Nomad registry but present in Nomad cache (deep clean)
	3. Remove previous versions' .LsZ files after package has been successfully removed 
	4. Verify package content has been removed from CCM cache for steps 1. and 2., if not manually remove it

# Logging and Reporting: 
Script log file %windir%\temp\nomadclean.log will provide overall execution of the script and information on the size of Nomad and CM cache before and after execution, number of unwanted packages removed from Nomad registry and cache, number of unwanted packages identified and removed as part of deep clean. 

A separate .JSON file for basic and deep clean will be created in %windir%\temp\  detailing each package ID and associated package version(s) removed. File name convention: pkgclnyyMMddHHmm.json ; dpclnyyMMddHHmm.json
  

