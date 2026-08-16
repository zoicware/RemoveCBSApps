[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param(
        [Parameter(Mandatory)]
        $Expected,

        [Parameter(Mandatory)]
        $Actual,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message Expected: [$Expected] Actual: [$Actual]"
    }
}

function Import-FunctionFromScript {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$errors
    )

    if ($errors.Count -ne 0) {
        throw "Unable to parse ${Path}: $($errors[0].Message)"
    }

    $functionAst = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $Name
        }, $true)

    if (!$functionAst) {
        throw "Function [$Name] was not found in [$Path]."
    }

    Set-Item -Path "Function:script:$Name" -Value $functionAst.Body.GetScriptBlock()
}

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'RemoveCBSApps.ps1'
Import-FunctionFromScript -Path $scriptPath -Name 'Disable-Resume'

$script:grantCalls = 0
$script:restoreCalls = 0

function Grant-AdminAccess {
    param([string]$Path)
    $script:grantCalls++
}

function Restore-TIOwner {
    param([string]$Path)
    $script:restoreCalls++
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "RemoveCBSApps-$([guid]::NewGuid())"
New-Item -Path $testRoot -ItemType Directory | Out-Null

try {
    $validXmlPath = Join-Path $testRoot 'valid.xml'
    $validXml = @'
<Package>
  <Applications>
    <Application Id="CrossDeviceResumeApp">
      <Extensions>
        <Extension>
          <AppExtension Name="com.microsoft.windows.extension.shelluihost">
            <Properties>
              <LaunchPolicy>1</LaunchPolicy>
              <LogonPolicy>1</LogonPolicy>
              <LaunchTimeoutPolicy>1</LaunchTimeoutPolicy>
            </Properties>
          </AppExtension>
        </Extension>
      </Extensions>
    </Application>
  </Applications>
</Package>
'@
    $validXml | Set-Content -LiteralPath $validXmlPath -Encoding utf8

    Disable-Resume -xmlPath $validXmlPath
    Assert-Equal -Expected 1 -Actual $script:grantCalls -Message 'Successful edit must grant access once.'
    Assert-Equal -Expected 1 -Actual $script:restoreCalls -Message 'Successful edit must restore ownership once.'

    [xml]$updated = Get-Content -LiteralPath $validXmlPath -Raw
    $properties = $updated.Package.Applications.Application.Extensions.Extension.AppExtension.Properties
    Assert-Equal -Expected '0' -Actual $properties.LaunchPolicy -Message 'LaunchPolicy was not updated.'
    Assert-Equal -Expected '0' -Actual $properties.LogonPolicy -Message 'LogonPolicy was not updated.'
    Assert-Equal -Expected '0' -Actual $properties.LaunchTimeoutPolicy -Message 'LaunchTimeoutPolicy was not updated.'

    $script:grantCalls = 0
    $script:restoreCalls = 0
    $fixedWriteTime = [datetime]::SpecifyKind([datetime]'2001-02-03T04:05:06', [DateTimeKind]::Utc)
    [IO.File]::SetLastWriteTimeUtc($validXmlPath, $fixedWriteTime)

    Disable-Resume -xmlPath $validXmlPath
    Assert-Equal -Expected 1 -Actual $script:grantCalls -Message 'No-op edit must grant access once.'
    Assert-Equal -Expected 1 -Actual $script:restoreCalls -Message 'No-op edit must restore ownership once.'
    Assert-Equal -Expected $fixedWriteTime -Actual ([IO.File]::GetLastWriteTimeUtc($validXmlPath)) -Message 'Already-disabled XML must not be rewritten.'

    $script:grantCalls = 0
    $script:restoreCalls = 0
    $readOnlyXmlPath = Join-Path $testRoot 'read-only.xml'
    $validXml | Set-Content -LiteralPath $readOnlyXmlPath -Encoding utf8
    [IO.File]::SetAttributes($readOnlyXmlPath, [IO.FileAttributes]::ReadOnly)

    $failed = $false
    try {
        Disable-Resume -xmlPath $readOnlyXmlPath
    }
    catch {
        $failed = $true
    }
    finally {
        [IO.File]::SetAttributes($readOnlyXmlPath, [IO.FileAttributes]::Normal)
    }

    Assert-Equal -Expected $true -Actual $failed -Message 'Read-only XML save must fail.'
    Assert-Equal -Expected 1 -Actual $script:grantCalls -Message 'Save failure must grant access once.'
    Assert-Equal -Expected 1 -Actual $script:restoreCalls -Message 'Save failure must restore ownership once.'

    $script:grantCalls = 0
    $script:restoreCalls = 0
    $invalidXmlPath = Join-Path $testRoot 'invalid.xml'
    '<Package>' | Set-Content -LiteralPath $invalidXmlPath -Encoding utf8

    $failed = $false
    try {
        Disable-Resume -xmlPath $invalidXmlPath
    }
    catch {
        $failed = $true
    }

    Assert-Equal -Expected $true -Actual $failed -Message 'Malformed XML must fail.'
    Assert-Equal -Expected 1 -Actual $script:grantCalls -Message 'Failure path must grant access once.'
    Assert-Equal -Expected 1 -Actual $script:restoreCalls -Message 'Failure path must restore ownership once.'

    Write-Host 'PASS: Disable-Resume avoids no-op writes and restores ownership after success, load failure, and save failure.'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
