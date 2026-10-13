# Nib - PowerShell Installer for Windows
# Usage:
#   irm https://raw.githubusercontent.com/nicklisac/nib/main/install.ps1 | iex

$ErrorActionPreference = 'Stop'

$Repo = "nicklisac/nib"
$Target = "windows-x64"
$InstallDir = "$HOME\.local\bin"

Write-Host "Fetching latest Nib release for $Target..." -ForegroundColor Cyan

# Fetch latest release info from GitHub API
try {
    $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ "User-Agent" = "nib-installer" }
    $LatestTag = $Release.tag_name
} catch {
    Write-Error "Failed to fetch latest release from GitHub API. Please check your internet connection."
    exit 1
}

if (-not $LatestTag) {
    Write-Error "Could not determine latest release tag."
    exit 1
}

$ArchiveName = "nib-$LatestTag-$Target.zip"
$DownloadUrl = "https://github.com/$Repo/releases/download/$LatestTag/$ArchiveName"

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

try {
    $ZipPath = Join-Path $TempDir $ArchiveName
    Write-Host "Downloading Nib $LatestTag..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $ZipPath

    Write-Host "Extracting..." -ForegroundColor Cyan
    Expand-Archive -Path $ZipPath -DestinationPath $TempDir -Force

    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    # Install binary
    $SourceExe = Join-Path $TempDir "nib.exe"
    $DestExe = Join-Path $InstallDir "nib.exe"
    Copy-Item -Path $SourceExe -Destination $DestExe -Force

    Write-Host "✔ Successfully installed Nib to $DestExe" -ForegroundColor Green

    # Install example config stub
    $SourceConfig = Join-Path $TempDir "config.example.json"
    $NibConfigDir = "$HOME\.nib"
    if (Test-Path $SourceConfig) {
        if (-not (Test-Path $NibConfigDir)) {
            New-Item -ItemType Directory -Path $NibConfigDir -Force | Out-Null
        }
        $DestConfig = Join-Path $NibConfigDir "config.example.json"
        Copy-Item -Path $SourceConfig -Destination $DestConfig -Force
        Write-Host "  Example config with every option: $DestConfig" -ForegroundColor Gray
    }

    # Ensure $InstallDir is in User PATH
    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $PathParts = $UserPath -split ';' | Where-Object { $_ -ne '' }
    if ($PathParts -notcontains $InstallDir) {
        Write-Host ""
        Write-Host "Adding $InstallDir to user PATH..." -ForegroundColor Yellow
        $NewPath = ($PathParts + $InstallDir) -join ';'
        [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
        $env:Path = "$env:Path;$InstallDir"
        Write-Host "✔ Added $InstallDir to PATH. Restart terminal or run: `$env:Path = [Environment]::GetEnvironmentVariable('Path', 'User')" -ForegroundColor Green
    }
} finally {
    Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
