# DocumentProcessor.psm1 — download, normalize, validate + compute content hash

function Invoke-ProcessDocument {
    <#
    .SYNOPSIS  Save raw bytes to local staging area; return metadata fragment.
    Returns @{ LocalPath; Hash; SizeBytes; Extension } or $null on failure.
    #>
    param(
        [byte[]]$Bytes,
        [string]$Url,
        [string]$ContentType,
        [string]$StagingDir
    )
    Import-Module (Join-Path $PSScriptRoot 'Logger.psm1') -Force -Global

    if (-not $Bytes -or $Bytes.Length -eq 0) {
        Write-Log -Level WARN -Category Processor -Message "Empty content for $Url"
        return $null
    }

    # Derive file extension from URL or content-type
    $ext = switch -Regex ($Url) {
        '\.pdf$'  { '.pdf'  }
        '\.docx$' { '.docx' }
        '\.xlsx$' { '.xlsx' }
        default   {
            if ($ContentType -match 'pdf')  { '.pdf'  }
            elseif ($ContentType -match 'html') { '.html' }
            else { '.bin' }
        }
    }

    # SHA-256 hash for deduplication
    $sha256   = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha256.ComputeHash($Bytes)
    $hash      = [System.BitConverter]::ToString($hashBytes) -replace '-', ''

    if (-not (Test-Path $StagingDir)) { New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null }

    # Filename: hash-based to avoid collisions and keep it idempotent
    $fileName  = "$hash$ext"
    $localPath = Join-Path $StagingDir $fileName

    [System.IO.File]::WriteAllBytes($localPath, $Bytes)
    Write-Log -Level INFO -Category Processor -Message "Saved $($Bytes.Length) bytes -> $localPath"

    return @{
        LocalPath   = $localPath
        Hash        = $hash
        SizeBytes   = $Bytes.Length
        Extension   = $ext
    }
}

function Test-DocumentValid {
    <# Minimal validation: file exists and is non-empty. #>
    param([string]$LocalPath)
    return (Test-Path $LocalPath) -and ((Get-Item $LocalPath).Length -gt 0)
}

Export-ModuleMember -Function Invoke-ProcessDocument, Test-DocumentValid
