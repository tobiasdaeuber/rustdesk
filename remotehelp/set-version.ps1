<#
.SYNOPSIS
    Sets the RemoteHelp client version (Cargo.toml and Cargo.lock).

.DESCRIPTION
    The version decides whether installed clients update: they take a release whose version is higher
    than their own. Use the RustDesk version for a plain rebuild of it ("1.5.1") and add a revision
    for RemoteHelp changes on top of the same RustDesk version ("1.5.1-1" ... "1.5.1-9"); the next
    RustDesk version ("1.5.2") is higher than every revision of the previous one.

    Commit and push the change, then run build-client.ps1 -Publish.

.EXAMPLE
    .\remotehelp\set-version.ps1 1.5.1-1
#>
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+(-[1-9])?$')]
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Update-File([string]$Path, [string]$Pattern, [string]$Replacement) {
    $text = [IO.File]::ReadAllText($Path)
    $regex = [regex]::new($Pattern, 'Multiline')
    if (-not $regex.IsMatch($text)) { throw "Version not found in $Path" }
    [IO.File]::WriteAllText($Path, $regex.Replace($text, $Replacement, 1))
}

# The first "version =" line of Cargo.toml is the package version; build scripts read it from there.
Update-File (Join-Path $root 'Cargo.toml') '^version = "[^"]*"' "version = `"$Version`""
Update-File (Join-Path $root 'Cargo.lock') '(?<=^name = "rustdesk"\r?\nversion = ")[^"]*' $Version
Write-Host "Version set to $Version. Commit and push, then run .\remotehelp\build-client.ps1 -Publish"
