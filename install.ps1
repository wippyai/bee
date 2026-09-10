# Install Bee from a published GitHub release on Windows.
#
# Usage: irm https://bee.wippy.ai/install.ps1 | iex
#        & ([scriptblock]::Create((irm https://bee.wippy.ai/install.ps1))) -Version 0.3.0 -Dir C:\bee
#
# Downloads bee-windows-<arch>.zip and its .sha256 document, verifies the
# archive, and places bee.exe in the destination directory (default
# %LOCALAPPDATA%\Programs\bee), adding it to the user PATH when missing.
[CmdletBinding()]
param(
    [string]$Version = 'latest',
    [string]$Dir = ''
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Fail([string]$Message) { Write-Error "bee install: $Message"; exit 1 }

if ($Dir -eq '') {
    if (-not $env:LOCALAPPDATA) { Fail 'LOCALAPPDATA is unset; use -Dir' }
    $Dir = Join-Path $env:LOCALAPPDATA 'Programs\bee'
}
$Dir = [IO.Path]::GetFullPath($Dir)

$architecture = switch ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    'X64'   { 'amd64' }
    'Arm64' { 'arm64' }
    default { Fail 'supported architectures: amd64 and arm64' }
}

$releaseUrl = 'https://github.com/wippyai/bee/releases'
if ($Version -eq 'latest') {
    $releaseUrl = "$releaseUrl/latest/download"
} else {
    $Version = $Version.TrimStart('v')
    if ($Version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?$') {
        Fail 'invalid release version'
    }
    $releaseUrl = "$releaseUrl/download/v$Version"
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) ("bee-install-" + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $temporary | Out-Null
try {
    $archive = "bee-windows-$architecture.zip"
    Write-Host "Downloading Bee (windows/$architecture, $Version)..."
    foreach ($asset in @($archive, "$archive.sha256")) {
        try {
            Invoke-WebRequest -Uri "$releaseUrl/$asset" -OutFile (Join-Path $temporary $asset) -MaximumRedirection 5 -TimeoutSec 600 -UseBasicParsing
        } catch {
            Fail "could not download $asset; check that the release is published"
        }
    }

    # Verify only the expected archive, even if the checksum document is malformed.
    $expected = $null
    foreach ($line in Get-Content (Join-Path $temporary "$archive.sha256")) {
        $fields = $line -split '\s+' | Where-Object { $_ -ne '' }
        if ($fields.Count -eq 2 -and $fields[1] -eq $archive) { $expected = $fields[0] }
    }
    if (-not $expected -or $expected.Length -ne 64 -or $expected -notmatch '^[0-9a-fA-F]+$') { Fail 'invalid checksum document' }
    $actual = (Get-FileHash -Algorithm SHA256 (Join-Path $temporary $archive)).Hash
    if ($expected.ToLowerInvariant() -ne $actual.ToLowerInvariant()) { Fail 'archive checksum mismatch' }

    $extracted = Join-Path $temporary 'extracted'
    Expand-Archive -Path (Join-Path $temporary $archive) -DestinationPath $extracted
    $binary = Get-ChildItem -Path $extracted -Recurse -Filter 'bee.exe' | Select-Object -First 1
    if (-not $binary) { Fail 'archive does not contain Bee' }
    if ($binary.Length -eq 0) { Fail 'archive contains an empty binary' }

    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $target = Join-Path $Dir 'bee.exe'
    if (Test-Path $target -PathType Container) { Fail 'destination bee.exe is a directory' }
    $staged = Join-Path $Dir ('.bee-install-' + [IO.Path]::GetRandomFileName())
    Copy-Item -Path $binary.FullName -Destination $staged
    Move-Item -Path $staged -Destination $target -Force
    Write-Host "Installed $target"

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $onPath = ($userPath -split ';' | Where-Object { $_ -ne '' } | ForEach-Object { [IO.Path]::GetFullPath($_.Trim()) }) -contains $Dir
    if (-not $onPath) {
        [Environment]::SetEnvironmentVariable('Path', (($userPath.TrimEnd(';')) + ';' + $Dir).TrimStart(';'), 'User')
        Write-Host "Added $Dir to your user PATH. Open a new terminal to run bee."
    }
} finally {
    Remove-Item -Path $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
