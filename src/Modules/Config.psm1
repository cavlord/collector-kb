# Config.psm1 — read/write persistent config; never stores tokens

$script:ConfigPath = $null

function Initialize-Config {
    param([string]$ConfigDir)
    if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
    $script:ConfigPath = Join-Path $ConfigDir "config.json"
}

function Get-Config {
    if (-not $script:ConfigPath -or -not (Test-Path $script:ConfigPath)) { return @{} }
    $raw = Get-Content $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    # Convert PSCustomObject to hashtable for easy key access
    $ht = @{}
    $raw.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
    return $ht
}

function Set-Config {
    param([hashtable]$Values)
    $current = Get-Config
    foreach ($k in $Values.Keys) { $current[$k] = $Values[$k] }
    # shortcut: no nested merge, flat keys only; upgrade if nested config needed
    $current | ConvertTo-Json -Depth 5 | Set-Content -Path $script:ConfigPath -Encoding UTF8
}

function Get-ConfigPath { return $script:ConfigPath }

Export-ModuleMember -Function Initialize-Config, Get-Config, Set-Config, Get-ConfigPath
