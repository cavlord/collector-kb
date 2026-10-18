# MetadataStore.psm1 — persist document metadata as a JSON line-delimited store
# Fields (PRD §8): judul, sourceUrl, kategori, subkategori, product, contentType,
#                  publishDate, ambilTanggal, hash, status, sharepointUrl

$script:StorePath = $null

function Initialize-MetadataStore {
    param([string]$DataDir)
    if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
    $script:StorePath = Join-Path $DataDir 'metadata.jsonl'
    if (-not (Test-Path $script:StorePath)) { New-Item -ItemType File -Path $script:StorePath -Force | Out-Null }
}

function Get-AllMetadata {
    if (-not $script:StorePath -or -not (Test-Path $script:StorePath)) { return @() }
    $lines = Get-Content $script:StorePath -Encoding UTF8 | Where-Object { $_.Trim() -ne '' }
    return $lines | ForEach-Object { $_ | ConvertFrom-Json }
}

function Get-MetadataByUrl {
    param([string]$Url)
    return Get-AllMetadata | Where-Object { $_.sourceUrl -eq $Url } | Select-Object -First 1
}

function Get-MetadataByHash {
    param([string]$Hash)
    return Get-AllMetadata | Where-Object { $_.hash -eq $Hash }
}

function Save-Metadata {
    <#
    .SYNOPSIS  Upsert a metadata record.
    Deduplication logic (PRD §10):
      - URL + hash same  -> skip (no change)
      - URL same + hash changed -> update (content changed)
      - URL different + hash same -> add with status 'potential-duplicate'
    #>
    param(
        [string]$Judul,
        [string]$SourceUrl,
        [string]$Kategori,
        [string]$Subkategori = '',
        [string]$Product     = '',
        [string]$ContentType,
        [string]$PublishDate = '',
        [string]$Hash,
        [string]$Status      = 'new',
        [string]$SharepointUrl = '',
        [string]$LocalPath   = ''
    )
    Import-Module (Join-Path $PSScriptRoot 'Logger.psm1') -Force -Global

    $now      = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ'
    $existing = Get-MetadataByUrl -Url $SourceUrl

    if ($existing) {
        if ($existing.hash -eq $Hash) {
            Write-Log -Level DEBUG -Category Metadata -Message "Skip unchanged: $SourceUrl"
            return 'skipped'
        }
        # Content changed — update in place by rewriting the store (small file assumption)
        $existing.hash         = $Hash
        $existing.status       = 'updated'
        $existing.ambilTanggal = $now
        $existing.localPath    = $LocalPath
        _RewriteStore -Updated $existing
        Write-Log -Level INFO -Category Metadata -Message "Updated: $SourceUrl"
        return 'updated'
    }

    # Potential duplicate by hash (different URL)
    $sameHash = Get-MetadataByHash -Hash $Hash
    if ($sameHash) {
        $Status = 'potential-duplicate'
        Write-Log -Level WARN -Category Metadata -Message "Potential duplicate hash $Hash for $SourceUrl (existing: $($sameHash[0].sourceUrl))"
    }

    $record = [ordered]@{
        judul         = $Judul
        sourceUrl     = $SourceUrl
        kategori      = $Kategori
        subkategori   = $Subkategori
        product       = $Product
        contentType   = $ContentType
        publishDate   = $PublishDate
        ambilTanggal  = $now
        hash          = $Hash
        status        = $Status
        sharepointUrl = $SharepointUrl
        localPath     = $LocalPath
    }

    Add-Content -Path $script:StorePath -Value ($record | ConvertTo-Json -Compress) -Encoding UTF8
    Write-Log -Level INFO -Category Metadata -Message "Recorded: $SourceUrl [$Status]"
    return $Status
}

function Update-MetadataStatus {
    param([string]$SourceUrl, [string]$Status, [string]$SharepointUrl = '')
    $all = Get-AllMetadata
    $target = $all | Where-Object { $_.sourceUrl -eq $SourceUrl } | Select-Object -First 1
    if (-not $target) { return }
    $target.status = $Status
    if ($SharepointUrl) { $target.sharepointUrl = $SharepointUrl }
    _RewriteStore -Updated $target
}

function _RewriteStore {
    param($Updated)
    $all = Get-AllMetadata
    $lines = $all | ForEach-Object {
        if ($_.sourceUrl -eq $Updated.sourceUrl) { $Updated | ConvertTo-Json -Compress }
        else { $_ | ConvertTo-Json -Compress }
    }
    Set-Content -Path $script:StorePath -Value $lines -Encoding UTF8
}

function Get-MetadataStats {
    $all = Get-AllMetadata
    return @{
        Total             = $all.Count
        New               = ($all | Where-Object { $_.status -eq 'new'                }).Count
        Updated           = ($all | Where-Object { $_.status -eq 'updated'            }).Count
        Uploaded          = ($all | Where-Object { $_.status -eq 'uploaded'           }).Count
        PotentialDuplicate= ($all | Where-Object { $_.status -eq 'potential-duplicate'}).Count
        Skipped           = ($all | Where-Object { $_.status -eq 'skipped'            }).Count
    }
}

Export-ModuleMember -Function Initialize-MetadataStore, Get-AllMetadata, Get-MetadataByUrl,
                               Get-MetadataByHash, Save-Metadata, Update-MetadataStatus, Get-MetadataStats
