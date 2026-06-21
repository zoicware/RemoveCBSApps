# RemoveCBSApps

This PowerShell script removes the Get Started and Windows Backup App from showing in the start menu and also disables CrossDeviceResume.exe from running.

## About

### CBS App Removal

These apps are bundled in with the Client.CBS appx package and are controlled via its appxmanifest.xml and StateRepository database. 
This script takes work from [win11-getstarted-backup-remover](https://github.com/psyloft/win11-getstarted-backup-remover) and [Remove_CBSStartMenuRubbish](https://github.com/JamieToll/Remove_CBSStartMenuRubbish). 
The problem is each of these methods alone will not work in some situations, so by using some of each method these apps can be sucessfully hidden regardless of the windows build.

#### How It Works
The script will set `AppListEntry` to `none` in both manifest files (package install location and AppRepository)

Then a copy of the StateRepository database is made and these app entrys are removed

After the script completes, the next reboot will replace the database file and run a cache clearing script to update StartMenuExperienceHost and ShellExperienceHost


### CrossDeviceResume Disable

Since build `26200.8514` CrossDeviceResume.exe no longer respects the feature mangement id to disable it.

Vivetool id (still found in the appxmanifest.xml):
```
vivetool.exe /disable /id:56517033
```

Registry:
```
[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\8\1387020943]
"EnabledState"=dword:00000001
```

> [!NOTE]
> If the feature management id does not work then this script's method will otherwise use the id above


#### How It Works

In Client.CBS appxmanifest CrossDeviceResume has these policies: `LaunchPolicy`, `LogonPolicy`, `LaunchTimeoutPolicy`

By setting these (really just LogonPolicy) to 0 CrossDeviceResume will no longer spawn on boot


## How to Use

Open PowerShell as Administrator

```PowerShell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/zoicware/RemoveCBSApps/refs/heads/main/RemoveCBSApps.ps1')))
```

### Disable Resume

> [!WARNING]
> If you want to disable resume AND remove Get Started/Backup App you need to run this step first
> 
```PowerShell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/zoicware/RemoveCBSApps/refs/heads/main/RemoveCBSApps.ps1'))) -DisableResume
```
