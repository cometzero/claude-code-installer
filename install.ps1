param(
    [Parameter(Position=0)]
    [ValidatePattern('^(stable|latest|\d+\.\d+\.\d+(-[^\s]+)?)$')]
    [string]$Target = "latest"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue'

if (-not [Environment]::Is64BitProcess) {
    Write-Error "Claude Code does not support 32-bit Windows. Please use a 64-bit version of Windows."
    exit 1
}

$Repo = if ($env:CLAUDE_CODE_INSTALL_REPO) { $env:CLAUDE_CODE_INSTALL_REPO } else { "cometzero/claude-code-installer" }
$ApiBase = "https://api.github.com/repos/$Repo"
$DownloadBase = "https://github.com/$Repo/releases/download"
$DownloadDir = "$env:USERPROFILE\.claude\downloads"
$InstallBaseDir = "$env:USERPROFILE\.claude\native"
$BinDir = "$env:USERPROFILE\.claude\bin"
$WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
New-Item -ItemType Directory -Force -Path $InstallBaseDir | Out-Null
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

function Normalize-Tag([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq "latest" -or $Value -eq "stable") {
        return $null
    }
    if ($Value.StartsWith("v")) {
        return $Value
    }
    return "v$Value"
}

function Resolve-Tag([string]$Requested) {
    if ([string]::IsNullOrWhiteSpace($Requested) -or $Requested -eq "latest" -or $Requested -eq "stable") {
        $AliasName = if ([string]::IsNullOrWhiteSpace($Requested)) { "latest" } else { $Requested }
        return (Invoke-RestMethod -Uri "$DownloadBase/$AliasName/alias.json").target_tag
    }
    $Normalized = Normalize-Tag $Requested
    return (Invoke-RestMethod -Uri "$ApiBase/releases/tags/$Normalized").tag_name
}

try {
    if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
        $Platform = "win32-arm64"
    }
    else {
        $Platform = "win32-x64"
    }

    $Tag = Resolve-Tag $Target
    if (-not $Tag) {
        Write-Error "Unable to resolve release tag for target '$Target'"
        exit 1
    }

    $Manifest = Invoke-RestMethod -Uri "$DownloadBase/$Tag/manifest.json"
    $PlatformEntry = $Manifest.platforms.$Platform
    if (-not $PlatformEntry) {
        Write-Error "Platform $Platform not found in manifest for $Tag"
        exit 1
    }

    $Asset = $PlatformEntry.asset
    $Checksum = $PlatformEntry.checksum.ToLower()
    $ArchiveFormat = $PlatformEntry.format
    $BinaryName = $PlatformEntry.binary
    $ArchivePath = Join-Path $WorkDir $Asset
    $ExtractDir = Join-Path $WorkDir "extracted"
    New-Item -ItemType Directory -Force -Path $ExtractDir | Out-Null

    Invoke-WebRequest -Uri "$DownloadBase/$Tag/$Asset" -OutFile $ArchivePath
    $ActualChecksum = (Get-FileHash -Path $ArchivePath -Algorithm SHA256).Hash.ToLower()
    if ($ActualChecksum -ne $Checksum) {
        Write-Error "Checksum verification failed for $Asset"
        exit 1
    }

    switch ($ArchiveFormat) {
        "zip" {
            Expand-Archive -Path $ArchivePath -DestinationPath $ExtractDir -Force
        }
        default {
            Write-Error "Unsupported archive format for Windows: $ArchiveFormat"
            exit 1
        }
    }

    $BinaryPath = Join-Path $ExtractDir $BinaryName
    if (-not (Test-Path $BinaryPath)) {
        Write-Error "Expected binary $BinaryName not found after extraction"
        exit 1
    }

    $InstallDir = Join-Path $InstallBaseDir "$Tag\$Platform"
    $InstalledBinary = Join-Path $InstallDir "claude.exe"
    $WrapperCmd = Join-Path $BinDir "claude.cmd"
    $WrapperPs1 = Join-Path $BinDir "claude.ps1"
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Copy-Item -Force $BinaryPath $InstalledBinary

    @"
@echo off
set DISABLE_UPDATES=1
"$InstalledBinary" %*
"@ | Set-Content -Path $WrapperCmd -Encoding ASCII

    @"
$env:DISABLE_UPDATES = '1'
& "$InstalledBinary" @args
"@ | Set-Content -Path $WrapperPs1 -Encoding UTF8

    $UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $PathEntries = @()
    if ($UserPath) { $PathEntries = $UserPath.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries) }
    if (-not ($PathEntries -contains $BinDir)) {
        $NewPath = if ($UserPath) { "$UserPath;$BinDir" } else { $BinDir }
        [Environment]::SetEnvironmentVariable('Path', $NewPath, 'User')
        Write-Output "Added $BinDir to the user PATH. Open a new shell to use 'claude'."
    }

    Write-Output "Installed Claude Code binary to: $InstalledBinary"
    Write-Output "Installed launchers to: $WrapperCmd and $WrapperPs1"
    Write-Output ""
    Write-Output "$([char]0x2705) Installation complete!"
    Write-Output ""
}
finally {
    if (Test-Path $WorkDir) {
        Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
