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
    6. With -Publish: signs update metadata with the update key and creates the GitHub release
       <version> in the fork, or adds the installer to it when the macOS build (build-client-macos.sh)
       has published it first. Installed clients take it once the RemoteHelp server announces it
       (portal: Settings -> Client updates).

    The token must be plugged in before step 3. Output goes to remotehelp\out\.
    The version comes from Cargo.toml of the built commit; set it with set-version.ps1.

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

.PARAMETER Publish
    Publish the signed installer as a GitHub release with signed update metadata.
    With -NoSign it becomes a pre-release titled "unsigned test": clients update to it just the same
    (they check the update metadata signature, not the code signature), Windows just warns on manual installs.

.PARAMETER UpdateKeyFile
    Base64 ed25519 seed of the update signing key. Its public half is compiled into the client
    (src/update_metadata.rs); without this file no further updates can be published - keep a backup.

.EXAMPLE
    .\remotehelp\build-client.ps1
.EXAMPLE
    .\remotehelp\build-client.ps1 -Publish
.EXAMPLE
    .\remotehelp\build-client.ps1 -RunId 12345678901 -Publish
.EXAMPLE
    .\remotehelp\build-client.ps1 -Publish -NoSign    # unsigned test release, e.g. to try the auto-update
#>
[CmdletBinding()]
param(
    [long]$RunId,
    [string]$Ref = 'remotehelp',
    [string]$Repo = 'tobiasdaeuber/rustdesk',
    [string]$CertThumbprint,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [switch]$NoSign,
    [switch]$Publish,
    [string]$UpdateKeyFile = (Join-Path $env:APPDATA 'RemoteHelp\update-signing\ed25519-seed.txt')
)

$ErrorActionPreference = 'Stop'
if ($Publish -and -not (Test-Path $UpdateKeyFile)) { throw "Update signing key not found: $UpdateKeyFile" }
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
if ($Publish) {
    & $python -c 'import cryptography' 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Installing the Python cryptography package (needed to sign update metadata)...'
        Invoke-Native $python @('-m', 'pip', 'install', '--user', '--quiet', 'cryptography')
    }
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
# The client's own version (Cargo.toml), which the updater compares; the file version info
# carries Flutter's version instead.
$version = (& (Join-Path $appDir "$AppName.exe") --version | Out-String).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+(-[1-9])?$') { throw "Unexpected client version '$version'" }
Write-Host "Client version: $version"
$releaseExists = $false
$otherArtifacts = @()
$releaseDir = Join-Path $Work 'release'
if ($Publish) {
    gh release view $version -R $Repo --json tagName 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        # Published by the macOS build first: the installer is added, and the metadata is signed again
        # for all installers of the release.
        New-Item -ItemType Directory -Force $releaseDir | Out-Null
        gh release download $version -R $Repo -p rustdesk-update.json -D $releaseDir 2>$null
        $existingMetadata = Join-Path $releaseDir 'rustdesk-update.json'
        if (-not (Test-Path $existingMetadata)) { throw "Release $version exists without rustdesk-update.json." }
        $artifacts = @((Get-Content $existingMetadata -Raw | ConvertFrom-Json).artifacts)
        if ($artifacts | Where-Object { $_.platform -eq 'windows' }) {
            throw "Release $version already has a Windows installer; raise the version with set-version.ps1 and rebuild."
        }
        $otherArtifacts = $artifacts
        $releaseExists = $true
        Write-Host "Release $version exists ($($artifacts.file_name -join ', ')); the installer will be added."
    }
}

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

if ($Publish) {
    Write-Step "Publishing release $version"
    $metadata = Join-Path $Out 'rustdesk-update.json'
    $signature = Join-Path $Out 'rustdesk-update.json.sig'
    $artifactArgs = @('--artifact', 'windows', 'x86_64', 'exe', $installer)
    foreach ($artifact in $otherArtifacts) {
        # Their hashes come from the downloaded files, not from the old metadata.
        Invoke-Native gh @('release', 'download', $version, '-R', $Repo, '-p', $artifact.file_name, '-D', $releaseDir, '--clobber')
        $artifactArgs += @('--artifact', $artifact.platform, $artifact.arch, $artifact.format, (Join-Path $releaseDir $artifact.file_name))
    }
    $env:RUSTDESK_UPDATE_ED25519_SEED = (Get-Content $UpdateKeyFile -Raw).Trim()
    try {
        # File names and schema are what the client's updater expects (src/updater/artifact.rs).
        Invoke-Native $python (@((Join-Path $RepoRoot 'res\update\generate_update_metadata.py'), 'sign') + $artifactArgs + @(
            '--version', $version, '--release-id', $version, '--package-id', 'rustdesk',
            '--release-base-url', "https://github.com/$Repo/releases/download",
            '--published-at', (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'),
            '--metadata-out', $metadata, '--signature-out', $signature))
    } finally {
        Remove-Item Env:RUSTDESK_UPDATE_ED25519_SEED
    }
    $notes = "RemoteHelp client $version for Windows x64, built by run https://github.com/$Repo/actions/runs/$RunId."
    if ($releaseExists) {
        Invoke-Native gh @('release', 'upload', $version, $installer, $metadata, $signature, '-R', $Repo, '--clobber')
        $existingNotes = gh release view $version -R $Repo --json body --jq .body | Out-String
        $notes = "$notes`n$($existingNotes.Trim())"
        if ($NoSign) { $notes += "`n`nWindows: unsigned test build (no code signature)." }
        Invoke-Native gh @('release', 'edit', $version, '-R', $Repo, '--notes', $notes)
    } else {
        $commit = gh run view "$RunId" -R $Repo --json headSha --jq .headSha
        $releaseArgs = @('release', 'create', $version, $installer, $metadata, $signature, '-R', $Repo, '--target', $commit)
        if ($NoSign) {
            $releaseArgs += @('--prerelease', '--title', "RemoteHelp $version (unsigned test)",
                '--notes', "$notes`n`nUnsigned test build (no code signature) for trying the auto-update.")
        } else {
            $releaseArgs += @('--title', "RemoteHelp $version", '--notes', $notes)
        }
        Invoke-Native gh $releaseArgs
    }
    Write-Host "Release: https://github.com/$Repo/releases/tag/$version"
    Write-Host "Roll it out in the RemoteHelp portal: Settings -> Client updates -> $version" -ForegroundColor Yellow
}

Write-Host ''
Write-Host "Done: $installer" -ForegroundColor Green
Write-Host "Unpacked app folder: $appDir"
