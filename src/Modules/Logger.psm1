# Logger.psm1 — structured log writer; never logs credentials or tokens

$script:LogPath = $null

function Initialize-Logger {
    param([string]$LogDir)
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $script:LogPath = Join-Path $LogDir "collector_$(Get-Date -Format 'yyyyMMdd').log"
}

function Write-Log {
    param(
        [ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level = 'INFO',
        [string]$Message,
        [string]$Category = 'General'
    )
    # Sanitize: strip anything that looks like a token/password before writing
    $safe = $Message -replace '(?i)(token|password|secret|bearer|authorization)[^\s]*\s*[=:]\s*\S+', '[REDACTED]'
    $safe = $safe    -replace 'Bearer\s+\S+', 'Bearer [REDACTED]'

    $entry = "[{0}] [{1}] [{2}] {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Category, $safe

    if ($script:LogPath) {
        Add-Content -Path $script:LogPath -Value $entry -Encoding UTF8
    }

    switch ($Level) {
        'ERROR' { Write-Host $entry -ForegroundColor Red }
        'WARN'  { Write-Host $entry -ForegroundColor Yellow }
        'DEBUG' { Write-Verbose $entry }
        default { Write-Host $entry }
    }
}

function Get-LogPath { return $script:LogPath }

Export-ModuleMember -Function Initialize-Logger, Write-Log, Get-LogPath
