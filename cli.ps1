#!/usr/bin/env pwsh
<#
.SYNOPSIS
  ibm-doc-collector — IBM Troubleshooting Documentation Collector CLI
.DESCRIPTION
  Collects IBM documentation from configured sources, deduplicates, and uploads to SharePoint.
.EXAMPLE
  ibm-doc-collector init
  ibm-doc-collector auth ibm
  ibm-doc-collector auth sharepoint
  ibm-doc-collector collect --category Support
  ibm-doc-collector status
  ibm-doc-collector report
  ibm-doc-collector doctor
#>
param(
    [Parameter(Position = 0)][string]$Command  = 'help',
    [Parameter(Position = 1)][string]$SubArg   = '',
    [string]$Category = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Paths ─────────────────────────────────────────────────────────────────────
$AppRoot   = $PSScriptRoot
$ModuleDir = Join-Path $AppRoot 'src\Modules'
$DataDir   = Join-Path $AppRoot 'data'
$LogDir    = Join-Path $DataDir 'logs'
$StagingDir= Join-Path $DataDir 'staging'

# ── Module imports ─────────────────────────────────────────────────────────────
Import-Module (Join-Path $ModuleDir 'Logger.psm1')           -Force -Global
Import-Module (Join-Path $ModuleDir 'Config.psm1')           -Force -Global
Import-Module (Join-Path $ModuleDir 'AuthManager.psm1')      -Force -Global
Import-Module (Join-Path $ModuleDir 'IbmSourceConnector.psm1') -Force -Global
Import-Module (Join-Path $ModuleDir 'DocumentProcessor.psm1') -Force -Global
Import-Module (Join-Path $ModuleDir 'MetadataStore.psm1')    -Force -Global
Import-Module (Join-Path $ModuleDir 'SharePointConnector.psm1') -Force -Global

Initialize-Logger     -LogDir $LogDir
Initialize-Config     -ConfigDir $DataDir
Initialize-MetadataStore -DataDir $DataDir

# ── Helpers ───────────────────────────────────────────────────────────────────
function Require-Config {
    param([string[]]$Keys)
    $cfg = Get-Config
    foreach ($k in $Keys) {
        if (-not $cfg.ContainsKey($k) -or -not $cfg[$k]) {
            Write-Host "Missing config key '$k'. Run: ibm-doc-collector init" -ForegroundColor Red
            exit 1
        }
    }
    return $cfg
}

# ══════════════════════════════════════════════════════════════════════════════
#  COMMANDS
# ══════════════════════════════════════════════════════════════════════════════

switch ($Command.ToLower()) {

    # ── init ──────────────────────────────────────────────────────────────────
    'init' {
        Write-Host "`n=== ibm-doc-collector init ===" -ForegroundColor Cyan

        $tenantId     = Read-Host "Microsoft Tenant ID"
        $siteId       = Read-Host "SharePoint Site ID (e.g. contoso.sharepoint.com,/sites/mysite)"
        $libraryName  = Read-Host "Document Library name [Documents]"
        if (-not $libraryName) { $libraryName = 'Documents' }
        $folderPath   = Read-Host "Destination folder path [IBM/Troubleshooting]"
        if (-not $folderPath)  { $folderPath  = 'IBM/Troubleshooting' }

        Set-Config @{
            tenantId    = $tenantId
            siteId      = $siteId
            libraryName = $libraryName
            folderPath  = $folderPath
        }

        # Ensure runtime directories exist
        foreach ($d in $LogDir, $StagingDir) {
            if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        }

        Write-Log -Level INFO -Message "Configuration saved."
        Write-Host "Done. Config written to: $(Get-ConfigPath)" -ForegroundColor Green
        Write-Host "Next steps:"
        Write-Host "  ibm-doc-collector auth ibm"
        Write-Host "  ibm-doc-collector auth sharepoint"
    }

    # ── auth ──────────────────────────────────────────────────────────────────
    'auth' {
        switch ($SubArg.ToLower()) {
            'ibm' {
                Write-Host "`n=== IBM Authentication ===" -ForegroundColor Cyan
                $user = Read-Host "IBMid email"
                $pass = Read-Host "IBMid password" -AsSecureString
                $ok   = Invoke-IbmLogin -Username $user -Password $pass
                if ($ok) {
                    Write-Host "IBM authentication successful." -ForegroundColor Green
                } else {
                    Write-Host "IBM authentication failed. Check credentials." -ForegroundColor Red
                    exit 1
                }
            }
            'sharepoint' {
                $cfg = Require-Config -Keys @('tenantId')
                Write-Host "`n=== Microsoft/SharePoint Authentication (device-code) ===" -ForegroundColor Cyan
                $ok  = Invoke-MicrosoftLogin -TenantId $cfg['tenantId']
                if ($ok) {
                    Write-Host "Microsoft authentication successful." -ForegroundColor Green
                } else {
                    Write-Host "Microsoft authentication failed." -ForegroundColor Red
                    exit 1
                }
            }
            default {
                Write-Host "Usage: ibm-doc-collector auth [ibm|sharepoint]" -ForegroundColor Yellow
                exit 1
            }
        }
    }

    # ── collect ───────────────────────────────────────────────────────────────
    'collect' {
        $cfg = Require-Config -Keys @('tenantId','siteId','libraryName','folderPath')

        if (-not (Test-IbmAuthenticated)) {
            Write-Host "IBM session not active. Run: ibm-doc-collector auth ibm" -ForegroundColor Red
            exit 1
        }
        if (-not (Test-MicrosoftAuthenticated)) {
            Write-Host "Microsoft session not active. Run: ibm-doc-collector auth sharepoint" -ForegroundColor Red
            exit 1
        }

        $httpClient  = Get-IbmHttpClient
        $sources     = Get-IbmSources -Config $cfg
        $filterCat   = if ($Category) { $Category } else { $null }

        $totalNew = 0; $totalSkipped = 0; $totalUpdated = 0

        foreach ($source in $sources) {
            if ($filterCat -and $source.Category -ne $filterCat) { continue }

            Write-Log -Level INFO -Message "Processing source: $($source.Id)"
            $docs = Get-IbmDocumentList -HttpClient $httpClient -Source $source -Category $filterCat

            foreach ($doc in $docs) {
                # Download
                $content = Get-IbmDocumentContent -HttpClient $httpClient -Url $doc.Url
                if (-not $content) { continue }

                # Process + hash
                $processed = Invoke-ProcessDocument -Bytes $content.Bytes -Url $doc.Url `
                                                    -ContentType $content.ContentType -StagingDir $StagingDir
                if (-not $processed) { continue }

                # Deduplication via metadata store
                $result = Save-Metadata -Judul $doc.Title -SourceUrl $doc.Url `
                                        -Kategori $doc.Category -Subkategori $doc.Subcategory `
                                        -Product $doc.Product -ContentType $doc.ContentType `
                                        -PublishDate ($doc.PublishDate ?? '') `
                                        -Hash $processed.Hash -Status 'new' `
                                        -LocalPath $processed.LocalPath

                if ($result -eq 'skipped') { $totalSkipped++; continue }

                # Upload to SharePoint
                $token    = Get-MicrosoftAccessToken
                $spUrl    = Invoke-UploadToSharePoint -AccessToken $token `
                                                      -TenantId $cfg['tenantId'] `
                                                      -SiteId $cfg['siteId'] `
                                                      -LibraryName $cfg['libraryName'] `
                                                      -FolderPath $cfg['folderPath'] `
                                                      -LocalFilePath $processed.LocalPath

                $finalStatus = if ($spUrl) { 'uploaded' } else { 'upload-failed' }
                Update-MetadataStatus -SourceUrl $doc.Url -Status $finalStatus -SharepointUrl ($spUrl ?? '')

                if ($result -eq 'updated') { $totalUpdated++ } else { $totalNew++ }
            }
        }

        Write-Host "`nCollection complete: $totalNew new, $totalUpdated updated, $totalSkipped skipped." -ForegroundColor Green
        Write-Log -Level INFO -Message "Collect done: new=$totalNew updated=$totalUpdated skipped=$totalSkipped"
    }

    # ── status ────────────────────────────────────────────────────────────────
    'status' {
        $stats = Get-MetadataStats
        Write-Host "`n=== Collection Status ===" -ForegroundColor Cyan
        $stats.GetEnumerator() | Sort-Object Name | ForEach-Object {
            Write-Host ("  {0,-22}: {1}" -f $_.Key, $_.Value)
        }
        $cfg = Get-Config
        Write-Host "`n  IBM authenticated     : $(Test-IbmAuthenticated)"
        Write-Host "  SharePoint authenticated: $(Test-MicrosoftAuthenticated)"
        if ($cfg.ContainsKey('siteId')) {
            Write-Host "  SharePoint Site       : $($cfg['siteId'])"
        }
    }

    # ── report ────────────────────────────────────────────────────────────────
    'report' {
        $all = Get-AllMetadata
        if ($all.Count -eq 0) {
            Write-Host "No records found. Run 'collect' first." -ForegroundColor Yellow
            return
        }
        $reportPath = Join-Path $DataDir "report_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        $all | Select-Object judul, kategori, subkategori, product, contentType,
                             publishDate, ambilTanggal, status, sourceUrl, sharepointUrl `
             | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8
        Write-Host "Report saved: $reportPath" -ForegroundColor Green
    }

    # ── doctor ────────────────────────────────────────────────────────────────
    'doctor' {
        Write-Host "`n=== Doctor Check ===" -ForegroundColor Cyan
        $checks = [ordered]@{}

        # PowerShell version
        $checks['PowerShell 7+'] = $PSVersionTable.PSVersion.Major -ge 7

        # Config file
        $cfgPath = Get-ConfigPath
        $checks['Config exists'] = $cfgPath -and (Test-Path $cfgPath)

        # Required config keys
        $cfg = Get-Config
        $checks['tenantId set']   = $cfg.ContainsKey('tenantId')    -and $cfg['tenantId']
        $checks['siteId set']     = $cfg.ContainsKey('siteId')      -and $cfg['siteId']
        $checks['libraryName set']= $cfg.ContainsKey('libraryName') -and $cfg['libraryName']

        # Auth state
        $checks['IBM authenticated']       = Test-IbmAuthenticated
        $checks['SharePoint authenticated']= Test-MicrosoftAuthenticated

        # Optional modules
        $checks['MSAL.PS installed']     = $null -ne (Get-Module -ListAvailable -Name MSAL.PS)
        $checks['Az.Accounts installed'] = $null -ne (Get-Module -ListAvailable -Name Az.Accounts)

        # SharePoint connectivity (only if authed)
        if (Test-MicrosoftAuthenticated -and $cfg.ContainsKey('siteId')) {
            try {
                $token = Get-MicrosoftAccessToken
                $checks['SharePoint reachable'] = Test-SharePointConnection -AccessToken $token -SiteId $cfg['siteId']
            } catch {
                $checks['SharePoint reachable'] = $false
            }
        }

        $allGood = $true
        foreach ($k in $checks.Keys) {
            $ok = $checks[$k]
            $icon  = if ($ok) { '✓' } else { '✗' }
            $color = if ($ok) { 'Green' } else { 'Red' }
            Write-Host ("  $icon  {0}" -f $k) -ForegroundColor $color
            if (-not $ok) { $allGood = $false }
        }

        Write-Host ""
        if ($allGood) {
            Write-Host "All checks passed." -ForegroundColor Green
        } else {
            Write-Host "Some checks failed. Address items marked ✗ above." -ForegroundColor Yellow
        }
    }

    # ── help / default ────────────────────────────────────────────────────────
    default {
        Write-Host @"

ibm-doc-collector — IBM Troubleshooting Documentation Collector

Usage:
  .\cli.ps1 init                        Configure tenant, site, library, folder
  .\cli.ps1 auth ibm                    Authenticate with IBMid
  .\cli.ps1 auth sharepoint             Authenticate with Microsoft (device-code)
  .\cli.ps1 collect [--category <cat>]  Fetch + upload documents
  .\cli.ps1 status                      Show collection + auth status
  .\cli.ps1 report                      Export CSV report
  .\cli.ps1 doctor                      Run environment health checks

"@
    }
}
