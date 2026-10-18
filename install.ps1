#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Installer global untuk ibm-doc-collector.
.DESCRIPTION
  Menyalin cli.ps1 dan semua modul ke direktori bin di LOCALAPPDATA,
  lalu mendaftarkan direktori tersebut ke PATH sistem (User scope).
.EXAMPLE
  .\install.ps1
#>
#Requires -Version 7.2

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BinDir     = Join-Path $env:LOCALAPPDATA 'ibm-doc-collector\bin'
$ScriptRoot = $PSScriptRoot
$ModuleDir  = Join-Path $ScriptRoot 'src\Modules'

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

# ── 3. Salin launcher .cmd ────────────────────────────────────────────────────
$cmdSrc = Join-Path $ScriptRoot 'ibm-doc-collector.cmd'
if (Test-Path $cmdSrc) {
    Copy-Item -Path $cmdSrc -Destination $BinDir -Force
    Write-Host "Disalin  : ibm-doc-collector.cmd" -ForegroundColor Cyan
}

# ── 4. Salin semua modul ──────────────────────────────────────────────────────
$destModules = Join-Path $BinDir 'src\Modules'
if (-not (Test-Path $destModules)) {
    New-Item -ItemType Directory -Path $destModules -Force | Out-Null
}
Get-ChildItem -Path $ModuleDir -Filter '*.psm1' | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $destModules -Force
    Write-Host "Disalin  : src\Modules\$($_.Name)" -ForegroundColor Cyan
}

# ── 5. Daftarkan ke PATH (User scope) ────────────────────────────────────────
$currentPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if (-not $currentPath) { $currentPath = '' }
if ($currentPath -split ';' -notcontains $BinDir) {
    [Environment]::SetEnvironmentVariable('PATH', "$currentPath;$BinDir", 'User')
    Write-Host "PATH diperbarui: $BinDir ditambahkan." -ForegroundColor Green
} else {
    Write-Host "PATH sudah mengandung direktori bin - tidak diubah." -ForegroundColor DarkGray
}

# ── 6. Verifikasi ─────────────────────────────────────────────────────────────
$resolved = Get-Command 'ibm-doc-collector' -ErrorAction SilentlyContinue
if ($resolved) {
    Write-Host "`nInstalasi selesai. Perintah 'ibm-doc-collector' tersedia di: $($resolved.Source)" -ForegroundColor Green
} else {
    Write-Host "`nInstalasi selesai." -ForegroundColor Green
    Write-Host "Catatan: buka sesi PowerShell baru agar perubahan PATH aktif, lalu jalankan:" -ForegroundColor Yellow
    Write-Host "  ibm-doc-collector help" -ForegroundColor Yellow
}
