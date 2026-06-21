param(
    [switch]$DisableResume
)

$TargetAppIds = @('WebExperienceHost', 'WindowsBackup')
$TargetAumids = @('MicrosoftWindows.Client.CBS_cw5n1h2txyewy!WebExperienceHost', 'MicrosoftWindows.Client.CBS_cw5n1h2txyewy!WindowsBackup')
$SRPath = "$env:ProgramData\Microsoft\Windows\AppRepository\StateRepository-Machine.srd"

if (-not ('ClientCBS.SQLite' -as [type])) {
    #lol dll usage of winsqlite3.dll to avoid mysqlite module dependency 
    Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

namespace ClientCBS {
    public static class SQLite {
        const string Lib = "winsqlite3.dll";
        const int SQLITE_ROW = 100;

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        static extern int sqlite3_open([MarshalAs(UnmanagedType.LPStr)] string f, out IntPtr db);

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        static extern int sqlite3_exec(IntPtr db, [MarshalAs(UnmanagedType.LPStr)] string sql,
            IntPtr cb, IntPtr arg, out IntPtr err);

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        static extern int sqlite3_prepare_v2(IntPtr db,
            [MarshalAs(UnmanagedType.LPStr)] string sql, int n, out IntPtr stmt, IntPtr tail);

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        static extern int sqlite3_step(IntPtr stmt);

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        static extern IntPtr sqlite3_column_text(IntPtr stmt, int col);

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        static extern int sqlite3_column_count(IntPtr stmt);

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        static extern int sqlite3_finalize(IntPtr stmt);

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        static extern int sqlite3_close(IntPtr db);

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        static extern IntPtr sqlite3_errmsg(IntPtr db);

        static string Str(IntPtr p) {
            return p == IntPtr.Zero ? null : Marshal.PtrToStringAnsi(p);
        }

        public static IntPtr Open(string path) {
            IntPtr db;
            int rc = sqlite3_open(path, out db);
            if (rc != 0) throw new Exception("sqlite3_open failed (" + rc + "): " + Str(sqlite3_errmsg(db)));
            return db;
        }

        public static void Exec(IntPtr db, string sql) {
            IntPtr err;
            int rc = sqlite3_exec(db, sql, IntPtr.Zero, IntPtr.Zero, out err);
            if (rc != 0)
                throw new Exception("sqlite3_exec failed (" + rc + "): " + Str(sqlite3_errmsg(db)) + " | SQL: " + sql);
        }

        public static List<string[]> Query(IntPtr db, string sql) {
            var rows = new List<string[]>();
            IntPtr stmt;
            if (sqlite3_prepare_v2(db, sql, -1, out stmt, IntPtr.Zero) != 0)
                throw new Exception("prepare_v2 failed: " + Str(sqlite3_errmsg(db)) + " | SQL: " + sql);
            try {
                int cols = sqlite3_column_count(stmt);
                while (sqlite3_step(stmt) == SQLITE_ROW) {
                    var row = new string[cols];
                    for (int i = 0; i < cols; i++)
                        row[i] = Str(sqlite3_column_text(stmt, i));
                    rows.Add(row);
                }
            } finally {
                sqlite3_finalize(stmt);
            }
            return rows;
        }

        public static void Close(IntPtr db) {
            sqlite3_close(db);
        }
    }

    public static class Kernel {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool MoveFileEx(string src, string dst, int flags);
    }
}
'@
}


function Grant-AdminAccess {
    param([string]$Path)
    takeown.exe /F $Path /A | Out-Null
    icacls.exe $Path /grant '*S-1-5-32-544:F' | Out-Null
}

function Restore-TIOwner {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        icacls.exe $Path /setowner 'NT SERVICE\TrustedInstaller' | Out-Null
    }
}

function Set-AppListEntryNone {
    param([string]$XmlPath, [string[]]$AppIds)
    Grant-AdminAccess $XmlPath
    try {
        $xml = [System.Xml.XmlDocument]::new()
        $xml.PreserveWhitespace = $true
        $xml.Load($XmlPath)
        $changed = $false
        foreach ($id in $AppIds) {
            $node = $xml.SelectSingleNode("//*[local-name()='Application'][@Id='$id']")
            if ($node) {
                $node.SetAttribute('AppListEntry', 'none')
                Write-Host "AppListEntry=none for: $id"
                $changed = $true
            }
        }
        if ($changed) { $xml.Save($XmlPath) }
    }
    finally {
        Restore-TIOwner $XmlPath
    }
}

function Disable-Resume {
    param(
        [string]$xmlPath
    )

    Grant-AdminAccess $XmlPath
    $XML = [System.Xml.XmlDocument]::new()
    $XML.PreserveWhitespace = $true
    $XML.Load($XmlPath)

    $xmlNode = $XML.Package.Applications.Application | Where-Object { $_.Id -Eq 'CrossDeviceResumeApp' }
    if ($xmlNode) {
        $extensions = $xmlNode.Extensions
        foreach ($ext in $extensions.Extension) {
            foreach ($appExt in $ext.AppExtension) {
                if ($appExt.Name -eq 'com.microsoft.windows.extension.shelluihost') {
                    $props = $appExt.Properties
                    if ($props.LaunchPolicy -ne $null) {
                        Write-Host 'Setting LaunchPolicy to 0...'
                        $props.LaunchPolicy = '0'
                    }
                    if ($props.LogonPolicy -ne $null) {
                        Write-Host 'Setting LogonPolicy to 0...'
                        $props.LogonPolicy = '0'
                    }
                    if ($props.LaunchTimeoutPolicy -ne $null) {
                        Write-Host 'Setting LaunchTimeoutPolicy to 0...'
                        $props.LaunchTimeoutPolicy = '0'
                    }
                }
            }
        }
        $XML.Save($XmlPath)
    }
    Restore-TIOwner $XmlPath
}

function Bump-ManifestVersion {
    param (
        [string]$xmlPath
    )
    Grant-AdminAccess $XmlPath
    try {
        $xml = [System.Xml.XmlDocument]::new()
        $xml.PreserveWhitespace = $true
        $xml.Load($XmlPath)
        $v = [System.Version]$xml.Package.Identity.Version
        $newVer = "$($v.Major).$($v.Minor).$($v.Build).$($v.Revision + 1)"
        $xml.Package.Identity.SetAttribute('Version', $newVer)
        $xml.Save($XmlPath)
        return $newVer
    }
    finally {
        Restore-TIOwner $XmlPath
    }
}

function Test-SRTable {
    param([IntPtr]$db, [string]$table)
    $t = $table.Replace("'", "''")
    return ([ClientCBS.SQLite]::Query($db, "SELECT name FROM sqlite_master WHERE type='table' AND name='$t';")).Count -gt 0
}

function Test-SRColumn {
    param([IntPtr]$db, [string]$table, [string]$column)
    if (-not (Test-SRTable $db $table)) { return $false }
    $rows = [ClientCBS.SQLite]::Query($db, "PRAGMA table_info([$table]);")
    return ($rows | Where-Object { $_[1] -eq $column }).Count -gt 0
}

function Remove-SRRows {
    param([IntPtr]$db, [string]$table, [string]$where)
    if (-not (Test-SRTable $db $table)) { 
        Write-Host "Skip missing table: $table"
        return 
    }
    [ClientCBS.SQLite]::Exec($db, "DELETE FROM [$table] WHERE $where;")
    Write-Host "Deleted from $($table): WHERE $where"
}

function Get-SRIds {
    param([IntPtr]$db, [string]$sql)
    $rows = [ClientCBS.SQLite]::Query($db, $sql)
    return @($rows | ForEach-Object { $_[0] } | Where-Object { $_ -ne $null -and $_ -ne '' } | Select-Object -Unique)
}

function Join-SqlList {
    param([string[]]$values)
    if (-not $values -or $values.Count -eq 0) { return $null }
    return $values -join ','
}


function Schedule-ReplaceOnReboot {
    param([string]$Source, [string]$Destination)
    if (-not [ClientCBS.Kernel]::MoveFileEx($Source, $Destination, 0x5)) {
        throw "MoveFileEx replace failed. Win32Error=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
}

function Schedule-DeleteOnReboot {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        [ClientCBS.Kernel]::MoveFileEx($Path, $null, 0x4) | Out-Null
        Write-Host "Scheduled delete: $Path"
    }
}


Write-Host 'Getting MicrosoftWindows.Client.CBS...'

$pkg = Get-AppxPackage -AllUsers -Name 'MicrosoftWindows.Client.CBS' | Select-Object -First 1
$InstallManifest = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
$RepoManifest = "C:\ProgramData\Microsoft\Windows\AppRepository\$($pkg.PackageFullName).xml"
$SRDir = Split-Path $SRPath
$NewSRPath = Join-Path $SRDir 'StateRepository-Machine.srd.new'
$WorkSRPath = Join-Path $env:TEMP 'ClientCBS-SR.work.srd'

if ($DisableResume) {
    Disable-Resume -xmlPath $InstallManifest
    if (Test-Path $RepoManifest) {
        Disable-Resume -xmlPath $RepoManifest
    }
    $ver = Bump-ManifestVersion -xmlPath $InstallManifest
    Write-Host "Updated Client.CBS Version to $ver..."
    Add-AppxPackage -Register -DisableDevelopmentMode -Path $InstallManifest -ForceApplicationShutdown -ForceUpdateFromAnyVersion 
    Write-Host 'DONE! CrossDeviceResume will not run on next reboot!' -ForegroundColor Green
}
else {
    Write-Host 'Patching InstallLocation AppxManifest.xml...'
    Set-AppListEntryNone -XmlPath $InstallManifest -AppIds $TargetAppIds

    Write-Host 'Patching AppRepository manifest...'
    if (Test-Path $RepoManifest) {
        Set-AppListEntryNone -XmlPath $RepoManifest -AppIds $TargetAppIds
    }
    else {
        Write-Host "Not found (will regenerate on next access): $RepoManifest" -ForegroundColor Yellow
    }

    Write-Host 'Creating StateRepository work copy...'
    if (Test-Path $WorkSRPath) { Remove-Item $WorkSRPath -Force }

    $srcDb = [ClientCBS.SQLite]::Open($SRPath)
    try {
        $escaped = $WorkSRPath.Replace("'", "''")
        [ClientCBS.SQLite]::Exec($srcDb, "VACUUM INTO '$escaped';")
    }
    finally {
        [ClientCBS.SQLite]::Close($srcDb)
    }


    Write-Host 'Removing target rows from work copy...'
    $db = [ClientCBS.SQLite]::Open($WorkSRPath)
    try {
        #create comma seperated list for sql search
        $aumiList = ($TargetAumids | ForEach-Object { "'$_'" }) -join ','

        #capture ids for each app for removal 
        $appRows = [ClientCBS.SQLite]::Query($db, "SELECT _ApplicationID, Activation FROM Application WHERE ApplicationUserModelId IN ($aumiList);")
        $appIds = @($appRows | ForEach-Object { $_[0] } | Where-Object { $_ })
        $actIds = @($appRows | ForEach-Object { $_[1] } | Where-Object { $_ })
        $identityIds = Get-SRIds $db "SELECT _ApplicationIdentityID FROM ApplicationIdentity WHERE ApplicationUserModelId IN ($aumiList);"
        $tileIds = Get-SRIds $db "SELECT _PrimaryTileID FROM PrimaryTile WHERE TileId IN ('WebExperienceHost','WindowsBackup');"

        if ($appIds.Count -gt 0) {
            $appIdList = Join-SqlList $appIds
            $extActIds = Get-SRIds $db "SELECT Activation FROM ApplicationExtension WHERE Application IN ($appIdList) AND Activation IS NOT NULL;"
            $actIds = @($actIds + $extActIds | Where-Object { $_ } | Select-Object -Unique)
        }

        $appIdList = Join-SqlList $appIds
        $identIdList = Join-SqlList $identityIds
        $tileIdList = Join-SqlList $tileIds
        $actIdList = Join-SqlList $actIds

        Write-Host "Application IDs:     $appIdList"
        Write-Host "ApplicationIdentity: $identIdList"
        Write-Host "PrimaryTile IDs:     $tileIdList"
        Write-Host "Activation IDs:      $actIdList"

        #drop all triggers
        $triggers = [ClientCBS.SQLite]::Query($db, "SELECT name, sql FROM sqlite_master WHERE type='trigger' ORDER BY name;")
        Write-Host "  Dropping $($triggers.Count) triggers"
        foreach ($t in $triggers) {
            if ($t[0]) { [ClientCBS.SQLite]::Exec($db, "DROP TRIGGER IF EXISTS [$($t[0])];") }
        }

        [ClientCBS.SQLite]::Exec($db, 'PRAGMA foreign_keys=OFF;')

        #delete dependent rows on ApplicationIdentity
        if ($identIdList) {
            foreach ($tbl in @('ApplicationUser', 'PrimaryTileUser', 'SecondaryTileUser')) {
                if (Test-SRColumn $db $tbl 'ApplicationIdentity') {
                    Remove-SRRows $db $tbl "ApplicationIdentity IN ($identIdList)"
                }
            }
        }

        #delete dependent rows on PrimaryTile
        if ($tileIdList) {
            foreach ($tbl in @('PrimaryTileUser', 'PrimaryTileUserChangelog')) {
                foreach ($col in @('PrimaryTile', '_PrimaryTileID')) {
                    if (Test-SRColumn $db $tbl $col) {
                        Remove-SRRows $db $tbl "$col IN ($tileIdList)"
                    }
                }
            }
        }

        #delete rows on Application
        if ($appIdList) {
            foreach ($tbl in @('ApplicationContentUriRule', 'ApplicationProperty', 'ApplicationExtension',
                    'ApplicationUser', 'MrtApplication', 'DefaultTile', 'PrimaryTile')) {
                if (Test-SRColumn $db $tbl 'Application') {
                    Remove-SRRows $db $tbl "Application IN ($appIdList)"
                }
            }
            Remove-SRRows $db 'Application' "_ApplicationID IN ($appIdList)"
        }

        #check all with tileId / AUMI / display name pattern
        Remove-SRRows $db 'PrimaryTile' "TileId IN ('WebExperienceHost','WindowsBackup')"
        if (Test-SRTable $db 'MrtApplication') {
            Remove-SRRows $db 'MrtApplication' "DisplayNameReference LIKE '%WebExperienceHost%'
            OR DisplayNameReference LIKE '%WindowsBackup%'
            OR DisplayNameReference LIKE '%GetStarted%'
            OR DisplayNameReference LIKE '%WindowsBackupHostName%'"
        }
        if ($identIdList) {
            Remove-SRRows $db 'ApplicationIdentity' "_ApplicationIdentityID IN ($identIdList)"
        }
        else {
            Remove-SRRows $db 'ApplicationIdentity' "ApplicationUserModelId IN ($aumiList)"
        }

        #remove activation rows
        if ($actIdList) {
            if (Test-SRColumn $db 'ApplicationExtension' 'Activation') {
                Remove-SRRows $db 'ApplicationExtension' "Activation IN ($actIdList)"
            }
            Remove-SRRows $db 'Activation' "_ActivationID IN ($actIdList)"
        }

        [ClientCBS.SQLite]::Exec($db, 'PRAGMA foreign_keys=ON;')

        #add back dropped triggers
        foreach ($t in $triggers) {
            if ($t[1]) { [ClientCBS.SQLite]::Exec($db, $t[1]) }
        }
        $restored = ([ClientCBS.SQLite]::Query($db, "SELECT name FROM sqlite_master WHERE type='trigger';")).Count
        if ($restored -ne $triggers.Count) {
            throw "Trigger count mismatch: expected $($triggers.Count), got $restored"
        }
    
        #check the integrity of the database to make sure the changes didnt mess something up
        $check = ([ClientCBS.SQLite]::Query($db, 'PRAGMA integrity_check;') | ForEach-Object { $_[0] }) -join ', '
        if ($check -notmatch 'ok') { throw "integrity_check failed: $check" }
        Write-Host "integrity_check: $check"

    }
    finally {
        [ClientCBS.SQLite]::Close($db)
    }

    Write-Host 'Scheduling StateRepository replacement on reboot...'
    Grant-AdminAccess $SRDir
    Copy-Item $WorkSRPath -Destination $NewSRPath -Force
    icacls.exe $NewSRPath /grant '*S-1-5-32-544:F' | Out-Null

    Schedule-ReplaceOnReboot -Source $NewSRPath -Destination $SRPath
    Write-Host "Scheduled swap: $NewSRPath -> $SRPath"

    foreach ($sidecar in @("$SRPath-wal", "$SRPath-shm", "$SRPath-journal")) {
        Schedule-DeleteOnReboot -Path $sidecar
    }

    Remove-Item $WorkSRPath -Force -ErrorAction SilentlyContinue

    Write-Host 'Registering RunOnce ClientCBS flush script...'

    $flushScript = Join-Path $env:ProgramData 'ClientCBS-Flush.ps1'
    @'
Write-Host "Re-registering StartMenuExperinceHost and ShellExperienceHost to refresh start icons..." -f green
Write-Host "Waiting 10 seconds before starting..." -f green
Start-Sleep 10

foreach ($proc in @('StartMenuExperienceHost','ShellExperienceHost','SearchHost','RuntimeBroker','explorer')) {
    Stop-Process -Name $proc -Force -ErrorAction SilentlyContinue
}

foreach ($pkg in @('Microsoft.Windows.StartMenuExperienceHost','Microsoft.Windows.ShellExperienceHost')) {
    $p = Get-AppxPackage $pkg -ErrorAction SilentlyContinue
    if ($p) { $p | Reset-AppxPackage }
}

Start-Sleep 3

foreach ($pkg in @('Microsoft.Windows.StartMenuExperienceHost','Microsoft.Windows.ShellExperienceHost')) {
    $p = Get-AppxPackage $pkg -ErrorAction SilentlyContinue
    if ($p) {
        $m = Join-Path $p.InstallLocation 'AppxManifest.xml'
        if (Test-Path $m) {
            Add-AppxPackage -DisableDevelopmentMode -Register $m -ForceApplicationShutdown -ErrorAction SilentlyContinue
        }
    }
}

Remove-Item $PSCommandPath -Force -ErrorAction SilentlyContinue
'@ | Set-Content $flushScript -Encoding UTF8

    $cmd = "powershell.exe -NonInteractive -ExecutionPolicy Bypass -File `"$flushScript`""
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name '!ClientCBS-FlushStartMenu' -Value $cmd -Type String

    Write-Host 'Reboot to apply changes. Get Started and Windows Backup will be gone after logon script finishes.' -ForegroundColor Green

}

