@echo off
:: Self-locating launcher for ibm-doc-collector.
:: Finds pwsh.exe and runs cli.ps1 with -ExecutionPolicy Bypass, forwarding all args.

setlocal

set "_DIR=%~dp0"
set "_CLI=%_DIR%cli.ps1"

:: 1) Coba pwsh (PowerShell 7)
where pwsh >nul 2>nul
if errorlevel 1 (
    :: 2) Fallback: Windows PowerShell 5.1 (yang sudah ada di Windows)
    where powershell >nul 2>nul
    if errorlevel 1 (
        echo Kesalahan: tidak ada pwsh.exe maupun powershell.exe.
        echo Instal PowerShell 7+ dari https://aka.ms/pscore6
        echo atau gunakan Windows PowerShell 5.1 yang sudah ada di Windows.
        exit /b 1
    )
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%_CLI%" %*
    exit /b %errorlevel%
)

pwsh.exe -ExecutionPolicy Bypass -NonInteractive -File "%_CLI%" %*
