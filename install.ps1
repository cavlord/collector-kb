#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Installer global untuk ibmi-doc-collector.
.DESCRIPTION
  Menyalin cli.ps1 dan semua modul ke direktori bin,
  lalu mendaftarkan direktori tersebut ke PATH.
  Windows : $LOCALAPPDATA\ibmi-doc-collector\bin
  macOS/Linux: $HOME/.local/share/ibmi-doc-collector/bin
.EXAMPLE
  .\install.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Deteksi platform (PS5.1 & PS7 kompatibel) ─────────────────────────────────────
$isWindows = ($env:OS -eq 'Windows_NT')

# ── Tentukan bin dir sesuai platform ─────────────────────────────────────────
if ($isWindows) {
    $BinDir = Join-Path $env:LOCALAPPDATA 'ibmi-doc-collector\bin'
} else {
    $BinDir = Join-Path $HOME '.local/share/ibmi-doc-collector/bin'
}

$ScriptRoot = $PSScriptRoot
$ModuleDir  = Join-Path $ScriptRoot 'src/Modules'

# ── 1. Buat direktori bin ─────────────────────────────────────────────────────
if (-not (Test-Path $BinDir)) {
    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    Write-Host "Direktori dibuat: $BinDir" -ForegroundColor Cyan
} else {
    Write-Host "Direktori bin sudah ada: $BinDir" -ForegroundColor DarkGray
}

# ── 2. Salin cli.ps1 ─────────────────────────────────────────────────────────
Copy-Item -Path (Join-Path $ScriptRoot 'cli.ps1') -Destination $BinDir -Force
Write-Host "Disalin  : cli.ps1" -ForegroundColor Cyan

# ── 3. Salin launcher .cmd (Windows only) ────────────────────────────────────
if ($isWindows) {
    $cmdSrc = Join-Path $ScriptRoot 'ibmi-doc-collector.cmd'
    if (Test-Path $cmdSrc) {
        Copy-Item -Path $cmdSrc -Destination $BinDir -Force
        Write-Host "Disalin  : ibmi-doc-collector.cmd" -ForegroundColor Cyan
    }
}

# ── 4. Salin semua modul ──────────────────────────────────────────────────────
$destModules = Join-Path $BinDir 'src/Modules'
if (-not (Test-Path $destModules)) {
    New-Item -ItemType Directory -Path $destModules -Force | Out-Null
}
Get-ChildItem -Path $ModuleDir -Filter '*.psm1' | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $destModules -Force
    Write-Host "Disalin  : src/Modules/$($_.Name)" -ForegroundColor Cyan
}

# ── 5. Daftarkan ke PATH ──────────────────────────────────────────────────────
if ($isWindows) {
    $currentPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if (-not $currentPath) { $currentPath = '' }
    if ($currentPath -split ';' -notcontains $BinDir) {
        [Environment]::SetEnvironmentVariable('PATH', "$currentPath;$BinDir", 'User')
        Write-Host "PATH diperbarui: $BinDir ditambahkan." -ForegroundColor Green
    } else {
        Write-Host "PATH sudah mengandung direktori bin - tidak diubah." -ForegroundColor DarkGray
    }
} else {
    $shell = if ($env:SHELL -like '*zsh*') { "$HOME/.zshrc" } else { "$HOME/.bashrc" }
    $exportLine = "export PATH=`"${BinDir}:$PATH`""
    $content = if (Test-Path $shell) { Get-Content $shell -Raw } else { '' }
    if ($content -notlike "*$BinDir*") {
        Add-Content -Path $shell -Value "`n# ibmi-doc-collector`n$exportLine"
        Write-Host "PATH ditambahkan ke $shell" -ForegroundColor Green
    } else {
        Write-Host "$shell sudah mengandung direktori bin - tidak diubah." -ForegroundColor DarkGray
    }
}

# ── 6. Verifikasi ─────────────────────────────────────────────────────────────
$resolved = Get-Command 'ibmi-doc-collector' -ErrorAction SilentlyContinue
if ($resolved) {
    Write-Host "`nInstalasi selesai. Perintah 'ibmi-doc-collector' tersedia di: $($resolved.Source)" -ForegroundColor Green
} else {
    Write-Host "`nInstalasi selesai." -ForegroundColor Green
    Write-Host "Catatan: buka sesi baru agar perubahan PATH aktif, lalu jalankan:" -ForegroundColor Yellow
    Write-Host "  ibmi-doc-collector help" -ForegroundColor Yellow
}
