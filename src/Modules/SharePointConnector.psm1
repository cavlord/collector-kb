# SharePointConnector.psm1 — upload documents via Microsoft Graph API
# Access token is passed in per-call; never stored to disk.

function Invoke-UploadToSharePoint {
    <#
    .SYNOPSIS  Upload a local file to a SharePoint document library folder via Graph.
    Returns the SharePoint item URL or $null on failure.
    #>
    param(
        [string]$AccessToken,
        [string]$TenantId,
        [string]$SiteId,        # SharePoint site id or relative path like "contoso.sharepoint.com,/sites/mysite"
        [string]$LibraryName,   # e.g. "Documents"
        [string]$FolderPath,    # e.g. "IBM/Support"
        [string]$LocalFilePath
    )
    Import-Module (Join-Path $PSScriptRoot 'Logger.psm1') -Force -Global

    if (-not (Test-Path $LocalFilePath)) {
        Write-Log -Level ERROR -Category SharePoint -Message "File not found: $LocalFilePath"
        return $null
    }

    $fileName  = Split-Path $LocalFilePath -Leaf
    $uploadUrl = "https://graph.microsoft.com/v1.0/sites/$SiteId/drives"

    try {
        # 1. Find the drive id for the library
        $headers = @{ Authorization = "Bearer $AccessToken"; 'Content-Type' = 'application/json' }
        $drivesResp = Invoke-RestMethod -Uri $uploadUrl -Headers $headers -Method Get
        $drive = $drivesResp.value | Where-Object { $_.name -eq $LibraryName } | Select-Object -First 1
        if (-not $drive) {
            Write-Log -Level ERROR -Category SharePoint -Message "Library '$LibraryName' not found on site $SiteId"
            return $null
        }

        # 2. Ensure folder exists (create if not)
        $folderApiUrl = "https://graph.microsoft.com/v1.0/drives/$($drive.id)/root:/$FolderPath"
        try {
            Invoke-RestMethod -Uri $folderApiUrl -Headers $headers -Method Get | Out-Null
        }
        catch {
            # Create folder
            $parentPath  = Split-Path $FolderPath -Parent
            $folderName  = Split-Path $FolderPath -Leaf
            $createUrl   = if ($parentPath) {
                'https://graph.microsoft.com/v1.0/drives/' + $drive.id + '/root:/' + $parentPath + ':/children'
            } else {
                'https://graph.microsoft.com/v1.0/drives/' + $drive.id + '/root/children'
            }
            $body = @{ name = $folderName; folder = @{}; '@microsoft.graph.conflictBehavior' = 'rename' } | ConvertTo-Json
            Invoke-RestMethod -Uri $createUrl -Headers $headers -Method Post -Body $body | Out-Null
            Write-Log -Level INFO -Category SharePoint -Message "Created folder: $FolderPath"
        }

        # 3. Upload (simple upload for files ≤4 MB; large-file session for larger)
        $fileBytes = [System.IO.File]::ReadAllBytes($LocalFilePath)
        $putUrl    = 'https://graph.microsoft.com/v1.0/drives/' + $drive.id + '/root:/' + $FolderPath + '/' + $fileName + ':/content'

        if ($fileBytes.Length -le 4MB) {
            $uploadHeaders = @{
                Authorization  = "Bearer $AccessToken"
                'Content-Type' = 'application/octet-stream'
            }
            $item = Invoke-RestMethod -Uri $putUrl -Headers $uploadHeaders -Method Put -Body $fileBytes
        }
        else {
            $item = _Upload-LargeFile -AccessToken $AccessToken -DriveId $drive.id `
                                      -RemotePath "$FolderPath/$fileName" -LocalPath $LocalFilePath
        }

        $webUrl = $item.webUrl
        Write-Log -Level INFO -Category SharePoint -Message "Uploaded $fileName -> $webUrl"
        return $webUrl
    }
    catch {
        Write-Log -Level ERROR -Category SharePoint -Message "Upload failed for $LocalFilePath : $($_.Exception.Message)"
        return $null
    }
}

function _Upload-LargeFile {
    param([string]$AccessToken, [string]$DriveId, [string]$RemotePath, [string]$LocalPath)

    $headers    = @{ Authorization = "Bearer $AccessToken"; 'Content-Type' = 'application/json' }
    $sessionUrl = 'https://graph.microsoft.com/v1.0/drives/' + $DriveId + '/root:/' + $RemotePath + ':/createUploadSession'
    $session    = Invoke-RestMethod -Uri $sessionUrl -Headers $headers -Method Post -Body '{}'
    $uploadUri  = $session.uploadUrl

    $stream    = [System.IO.File]::OpenRead($LocalPath)
    $chunkSize = 5MB
    $buffer    = [byte[]]::new($chunkSize)
    $offset    = 0
    $total     = (Get-Item $LocalPath).Length
    $item      = $null

    try {
        while ($offset -lt $total) {
            $read = $stream.Read($buffer, 0, $chunkSize)
            $chunk = $buffer[0..($read-1)]
            $end   = $offset + $read - 1
            $rangeHeaders = @{
                'Content-Range'  = "bytes $offset-$end/$total"
                'Content-Length' = $read
            }
            $item = Invoke-RestMethod -Uri $uploadUri -Method Put -Body $chunk -Headers $rangeHeaders
            $offset += $read
        }
    }
    finally { $stream.Close() }

    return $item
}

function Test-SharePointConnection {
    param([string]$AccessToken, [string]$SiteId)
    try {
        $headers = @{ Authorization = "Bearer $AccessToken" }
        Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId" -Headers $headers | Out-Null
        return $true
    }
    catch { return $false }
}

Export-ModuleMember -Function Invoke-UploadToSharePoint, Test-SharePointConnection
