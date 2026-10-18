param(
    [Parameter(Position = 0)][string]$Command  = 'help',
    [Parameter(Position = 1)][string]$SubArg   = '',
    [Parameter(Position = 2)][string]$Category = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#  Paths 
$AppRoot   = $PSScriptRoot
$ModuleDir = Join-Path $AppRoot 'src\Modules'
$DataDir   = Join-Path $AppRoot 'data'
$LogDir    = Join-Path $DataDir 'logs'
$StagingDir= Join-Path $DataDir 'staging'

#  Module imports 
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

#--- Banner --------------------------------------------------------------------
$_version = '1.0.0'
$ProjectName = 'IBMi'
Write-Host ""
Write-Host "  ___ ___   ___  ___   ___   ___  ___  ___ "
Write-Host " | __| _ \ / _ \| _ \ / _ \ / _ \| _ \| _ \ "
Write-Host " | _||   /|  _/|  _/ \  _/ \  _/|  _/|  _/ "
Write-Host " |___|__\_\|___|_|   |_||_| |_||_| |_| |_|_| "
Write-Host ""
Write-Host "  v$_version  |  $ProjectName Troubleshooting Documentation Collector"
Write-Host "  $('-' * 60)"
Write-Host ""

#  Helpers 
function Coalesce {
    param([object]$Left, [object]$Right)
    if ($null -ne $Left) { $Left } else { $Right }
}

function Require-Config {
    param([string[]]$Keys)
    $cfg = Get-Config
    foreach ($k in $Keys) {
        if (-not $cfg.ContainsKey($k) -or -not $cfg[$k]) {
            Write-Host "Missing config key '$k'. Run: ibmi-doc-collector init" -ForegroundColor Red
            exit 1
        }
    }
    return $cfg
}

# 
#  COMMANDS
# 

switch ($Command.ToLower()) {

    #  init 
    'init' {
        Write-Host "`n=== ibmi-doc-collector init ===" -ForegroundColor Cyan

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
        Write-Host "  ibmi-doc-collector auth ibm sso"
        Write-Host "  ibmi-doc-collector auth sharepoint"
    }

    #  auth
    'auth' {
        switch ($SubArg.ToLower()) {
            'ibm' {
                if ($Category -eq 'sso') {
                    Write-Host "`n=== IBM SSO Authentication ===" -ForegroundColor Cyan
                    $ok = Invoke-IbmLoginSSO
                    if ($ok) {
                        Write-Host "IBM authentication successful." -ForegroundColor Green
                    } else {
                        Write-Host "IBM authentication failed." -ForegroundColor Red
                        exit 1
                    }
                } else {
                    Write-Host "Manual password login is deprecated and removed." -ForegroundColor Yellow
                    Write-Host "Please use: ibmi-doc-collector auth ibm sso" -ForegroundColor Yellow
                    exit 1
                }
            }
            'ibm sso' {
                # shortcut: dead branch — $SubArg is one token, never 'ibm sso'; kept for clarity
                if ($Category -eq 'sso') {
                    Write-Host "`n=== IBM SSO Authentication ===" -ForegroundColor Cyan
                    $ok = Invoke-IbmLoginSSO
                    if ($ok) {
                        Write-Host "IBM authentication successful." -ForegroundColor Green
                    } else {
                        Write-Host "IBM authentication failed." -ForegroundColor Red
                        exit 1
                    }
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
                Write-Host "Usage: ibmi-doc-collector auth [ibm sso|sharepoint]" -ForegroundColor Yellow
                exit 1
            }
        }
    }

    #  collect
    'collect' {
        $cfg = Require-Config -Keys @('tenantId','siteId','libraryName','folderPath')

        if (-not (Test-IbmAuthenticated)) {
            Write-Host "IBM session not active. Run: ibmi-doc-collector auth ibm sso" -ForegroundColor Red
            exit 1
        }
        if (-not (Test-MicrosoftAuthenticated)) {
            Write-Host "Microsoft session not active. Run: ibmi-doc-collector auth sharepoint" -ForegroundColor Red
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
                                        -PublishDate (Coalesce $doc.PublishDate '') `
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
                Update-MetadataStatus -SourceUrl $doc.Url -Status $finalStatus -SharepointUrl (Coalesce $spUrl '')

                if ($result -eq 'updated') { $totalUpdated++ } else { $totalNew++ }
            }
        }

        Write-Host "`nCollection complete: $totalNew new, $totalUpdated updated, $totalSkipped skipped." -ForegroundColor Green
        Write-Log -Level INFO -Message "Collect done: new=$totalNew updated=$totalUpdated skipped=$totalSkipped"
    }

    #  status 
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

    #  report 
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

    #  doctor 
    'doctor' {
        Write-Host "`n=== Doctor Check ===" -ForegroundColor Cyan
        # Values: 'ok' | 'warn' (fixable via init/login) | 'fail' (truly broken)
        $cfg     = Get-Config
        $cfgPath = Get-ConfigPath

        $checks = [ordered]@{}
        $st = { param($b, $bad = 'warn') if ($b) { 'ok' } else { $bad } }

        # App supports PS 5.1+
        $v = $PSVersionTable.PSVersion
        $checks['PowerShell 5.1+'] = & $st ($v.Major -gt 5 -or ($v.Major -eq 5 -and $v.Minor -ge 1)) 'fail'

        $checks['Config exists']   = & $st ($cfgPath -and (Test-Path $cfgPath))
        foreach ($key in 'tenantId', 'siteId', 'libraryName') {
            $checks["$key set"] = & $st ($cfg.ContainsKey($key) -and $cfg[$key])
        }
        $checks['IBM authenticated']        = & $st (Test-IbmAuthenticated)
        $checks['SharePoint authenticated'] = & $st (Test-MicrosoftAuthenticated)

        # Either module is enough; only required once SharePoint is configured
        $hasAuthModule = (Get-Module -ListAvailable -Name MSAL.PS) -or (Get-Module -ListAvailable -Name Az.Accounts)
        $hasSiteId     = $cfg.ContainsKey('siteId') -and $cfg['siteId']
        $checks['MSAL.PS or Az.Accounts installed'] = & $st (-not $hasSiteId -or $hasAuthModule) 'warn'

        # SharePoint connectivity (only if authed): authed + configured but unreachable is broken
        if ($checks['SharePoint authenticated'] -eq 'ok' -and $hasSiteId) {
            try {
                $token = Get-MicrosoftAccessToken
                $checks['SharePoint reachable'] = & $st (Test-SharePointConnection -AccessToken $token -SiteId $cfg['siteId']) 'fail'
            } catch {
                $checks['SharePoint reachable'] = 'fail'
            }
        }

        $mark  = @{ ok = '[OK]  '; warn = '[WARN]'; fail = '[FAIL]' }
        $color = @{ ok = 'Green';  warn = 'Yellow'; fail = 'Red' }
        foreach ($k in $checks.Keys) {
            $s = $checks[$k]
            Write-Host ("  {0} {1}" -f $mark[$s], $k) -ForegroundColor $color[$s]
        }

        $failed = @($checks.Values | Where-Object { $_ -eq 'fail' }).Count
        $warned = @($checks.Values | Where-Object { $_ -eq 'warn' }).Count
        Write-Host ""
        if ($failed) {
            Write-Host "$failed check(s) failed. Fix items marked [FAIL]." -ForegroundColor Red
        } elseif ($warned) {
            Write-Host "No failures. $warned warning(s): run 'init' / login to complete setup." -ForegroundColor Yellow
        } else {
            Write-Host "All checks passed." -ForegroundColor Green
        }
    }

    #  help / default 
    default {
        Write-Host @"

ibmi-doc-collector  IBM Troubleshooting Documentation Collector

Usage:
  .\cli.ps1 init                        Configure tenant, site, library, folder
  .\cli.ps1 auth ibm sso                Authenticate with IBMid SSO
  .\cli.ps1 auth sharepoint             Authenticate with Microsoft (device-code)
  .\cli.ps1 collect [--category <cat>]  Fetch + upload documents
  .\cli.ps1 status                      Show collection + auth status
  .\cli.ps1 report                      Export CSV report
  .\cli.ps1 doctor                      Run environment health checks

"@
    }
}

#  Banner 
$_version = '1.0.0'
Write-Host ""
Write-Host "  ___ ___   ___  ___   ___   ___  ___  ___ "
Write-Host " | __| _ \ / _ \| _ \ / _ \ / _ \| _ \| _ \ "
Write-Host " | _||   /|  _/|  _/ \  _/ \  _/|  _/|  _/ "
Write-Host " |___|_|_\_|___|_|   |_||_| |_||_| |_| |_|_| "
Write-Host ""
Write-Host "  v$_version  |  $ProjectName  Documentation Collector"
Write-Host "  $('-' * 60)"
Write-Host ""


