<#
.SYNOPSIS
    Builds the RemoteHelp Windows client on GitHub Actions and signs it here with the code-signing token.

.DESCRIPTION
    1. Starts the "RemoteHelp Windows x64" workflow in the fork and waits for it (roughly 45-75 minutes).
    2. Downloads the unsigned app folder and the packer template.
    3. Renames rustdesk.exe to RemoteHelp.exe and signs every unsigned .exe/.dll with signtool
       (one signtool call, so the token asks for its PIN once).
    4. Packs the signed folder into the template's RDPKG resource -> RemoteHelp-<version>-x86_64.exe.
    5. Signs that installer and verifies both signatures.

    The token must be plugged in before step 3. Output goes to remotehelp\out\.

.PARAMETER RunId
    Use the artifact of an existing workflow run instead of starting a new build.

.PARAMETER Ref
    Branch of the fork to build. Default: remotehelp.

.PARAMETER CertThumbprint
    SHA-1 thumbprint of the signing certificate. Default: signtool picks the best one (/a).

.PARAMETER TimestampUrl
    RFC 3161 timestamp server. Default: http://timestamp.digicert.com

.PARAMETER NoSign
    Skip signing (for testing the pipeline without the token).

.EXAMPLE
    .\remotehelp\build-client.ps1
.EXAMPLE
    .\remotehelp\build-client.ps1 -RunId 12345678901
#>
[CmdletBinding()]
param(
    [long]$RunId,
    [string]$Ref = 'remotehelp',
    [string]$Repo = 'tobiasdaeuber/rustdesk',
    [string]$CertThumbprint,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [switch]$NoSign
)

$ErrorActionPreference = 'Stop'
$Workflow = 'remotehelp-windows.yml'
$Artifact = 'remotehelp-windows-x86_64'
$AppName = 'RemoteHelp'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Out = Join-Path $PSScriptRoot 'out'
$Work = Join-Path $Out 'work'

function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
}

function Find-SignTool {
    $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $found = Get-ChildItem $kits -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -eq 'x64' } | Sort-Object FullName | Select-Object -Last 1
    if (-not $found) { throw 'signtool.exe not found; install the Windows SDK.' }
    return $found.FullName
}

function Invoke-Sign([string[]]$Files) {
    if ($NoSign -or $Files.Count -eq 0) { return }
    $certArgs = if ($CertThumbprint) { @('/sha1', $CertThumbprint) } else { @('/a') }
    Invoke-Native $script:SignTool (@('sign', '/fd', 'sha256', '/tr', $TimestampUrl, '/td', 'sha256') + $certArgs + $Files)
}

# Writes $Payload into the RCDATA resource "RDPKG" of $Exe, which the packer reads at startup.
function Set-PackagePayload([string]$Exe, [string]$Payload) {
    if (-not ('RemoteHelp.ResourceWriter' -as [type])) {
        Add-Type -Namespace RemoteHelp -Name ResourceWriter -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr BeginUpdateResource(string pFileName, bool bDeleteExistingResources);
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool UpdateResource(IntPtr hUpdate, IntPtr lpType, string lpName, ushort wLanguage, byte[] lpData, uint cbData);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool EndUpdateResource(IntPtr hUpdate, bool fDiscard);
'@
    }
    $bytes = [IO.File]::ReadAllBytes($Payload)
    $handle = [RemoteHelp.ResourceWriter]::BeginUpdateResource($Exe, $false)
    if ($handle -eq [IntPtr]::Zero) { throw "BeginUpdateResource failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
    # RT_RCDATA = 10, LANG_NEUTRAL = 0
    if (-not [RemoteHelp.ResourceWriter]::UpdateResource($handle, [IntPtr]10, 'RDPKG', 0, $bytes, [uint32]$bytes.Length)) {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        [void][RemoteHelp.ResourceWriter]::EndUpdateResource($handle, $true)
        throw "UpdateResource failed: $err"
    }
    if (-not [RemoteHelp.ResourceWriter]::EndUpdateResource($handle, $false)) {
        throw "EndUpdateResource failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
}

# --- Prerequisites -----------------------------------------------------------------------------
Write-Step 'Checking prerequisites'
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI (gh) not found.' }
Invoke-Native gh @('auth', 'status')
$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) { throw 'Python not found.' }
& $python -c 'import brotli' 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Installing the Python brotli package (needed to pack the installer)...'
    Invoke-Native $python @('-m', 'pip', 'install', '--user', '--quiet', 'brotli')
}
if (-not $NoSign) { $script:SignTool = Find-SignTool }

# --- Build on GitHub Actions -------------------------------------------------------------------
if (-not $RunId) {
    Write-Step "Starting $Workflow on $Repo@$Ref"
    $started = (Get-Date).ToUniversalTime().AddSeconds(-5)
    Invoke-Native gh @('workflow', 'run', $Workflow, '-R', $Repo, '--ref', $Ref)
    for ($i = 0; $i -lt 30 -and -not $RunId; $i++) {
        Start-Sleep -Seconds 4
        $runs = gh run list -R $Repo -w $Workflow -b $Ref -e workflow_dispatch -L 5 --json databaseId,createdAt | ConvertFrom-Json
        $run = $runs | Where-Object { ([datetime]$_.createdAt).ToUniversalTime() -ge $started } | Select-Object -First 1
        if ($run) { $RunId = $run.databaseId }
    }
    if (-not $RunId) { throw 'The workflow run did not show up; check https://github.com/' + $Repo + '/actions' }
    Write-Host "Run: https://github.com/$Repo/actions/runs/$RunId"
    Write-Step 'Waiting for the build (usually 45-75 minutes)'
    Invoke-Native gh @('run', 'watch', "$RunId", '-R', $Repo, '--exit-status', '--interval', '60')
}

Write-Step "Downloading artifact of run $RunId"
if (Test-Path $Work) { Remove-Item $Work -Recurse -Force }
New-Item -ItemType Directory -Force $Work | Out-Null
Invoke-Native gh @('run', 'download', "$RunId", '-R', $Repo, '-n', $Artifact, '-D', $Work)
$appDir = Join-Path $Work 'rustdesk'
$template = Join-Path $Work 'packer\packer-template.exe'
if (-not (Test-Path (Join-Path $appDir 'rustdesk.exe')) -or -not (Test-Path $template)) {
    throw "The artifact does not contain rustdesk\rustdesk.exe and packer\packer-template.exe."
}

# The process must be <app name>.exe; the app relies on it to find its own processes.
Rename-Item (Join-Path $appDir 'rustdesk.exe') "$AppName.exe"
$version = (Get-Item (Join-Path $appDir "$AppName.exe")).VersionInfo.ProductVersion
# Drop the build metadata ("1.5.1+68" -> "1.5.1") for the file name.
$version = if ($version) { ($version -split '\+')[0] } else { 'dev' }

# --- Sign the app files ------------------------------------------------------------------------
Write-Step $(if ($NoSign) { 'Listing unsigned app files (-NoSign: not signing)' } else { 'Signing the app files (the token may ask for its PIN)' })
$unsigned = Get-ChildItem $appDir -Recurse -Include *.exe, *.dll |
    Where-Object { (Get-AuthenticodeSignature $_.FullName).Status -ne 'Valid' } |
    ForEach-Object { $_.FullName }
Write-Host "$($unsigned.Count) unsigned files"
Invoke-Sign $unsigned

# --- Pack into the self-extracting installer ---------------------------------------------------
Write-Step 'Packing the installer'
$payload = Join-Path $Work 'payload.bin'
Invoke-Native $python @((Join-Path $RepoRoot 'libs\portable\generate.py'), '-f', $appDir, '-e', "$AppName.exe", '--package', $payload)
$installer = Join-Path $Out "$AppName-$version-x86_64.exe"
Copy-Item $template $installer -Force
Set-PackagePayload $installer $payload

if (-not $NoSign) {
    Write-Step 'Signing the installer'
    Invoke-Sign @($installer)
}

if (-not $NoSign) {
    Write-Step 'Verifying signatures'
    Invoke-Native $script:SignTool @('verify', '/pa', '/q', $installer, (Join-Path $appDir "$AppName.exe"))
}

Write-Host ''
Write-Host "Done: $installer" -ForegroundColor Green
Write-Host "Unpacked app folder: $appDir"
