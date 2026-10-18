@echo off
:: Self-locating launcher for ibm-doc-collector.
:: Finds pwsh.exe and runs cli.ps1 with -ExecutionPolicy Bypass, forwarding all args.

setlocal

set "_DIR=%~dp0"
set "_CLI=%_DIR%cli.ps1"

where pwsh >nul 2>&1
if errorlevel 1 (
    echo Kesalahan: pwsh.exe tidak ditemukan. Instal PowerShell 7+ dari https://aka.ms/pscore6
    exit /b 1
)

pwsh.exe -ExecutionPolicy Bypass -NonInteractive -File "%_CLI%" %*
