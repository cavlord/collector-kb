# IbmSourceConnector.psm1 — fetch document lists + content from IBM sources

# Built-in source catalog; extend by editing config sources list
$script:DefaultSources = @(
    @{ Id = 'ibm-support';    BaseUrl = 'https://www.ibm.com/support/pages/';      Category = 'Support'       }
    @{ Id = 'ibm-docs';       BaseUrl = 'https://www.ibm.com/docs/';               Category = 'Documentation' }
    @{ Id = 'ibm-redbooks';   BaseUrl = 'https://www.redbooks.ibm.com/';           Category = 'Redbooks'      }
    @{ Id = 'ibm-technotes';  BaseUrl = 'https://www.ibm.com/support/knowledgecenter/'; Category = 'TechNotes' }
)

function Get-IbmSources {
    <# Returns the active source list from config, falling back to defaults. #>
    param([hashtable]$Config)
    if ($Config.ContainsKey('sources') -and $Config['sources']) {
        return $Config['sources']
    }
    return $script:DefaultSources
}

function Get-IbmDocumentList {
    <#
    .SYNOPSIS  Retrieve a list of document descriptors from a given IBM source.
    Returns array of @{ Title; Url; Category; Subcategory; Product; ContentType; PublishDate }
    #>
    param(
        [System.Net.Http.HttpClient]$HttpClient,
        [hashtable]$Source,
        [string]$Category = $null
    )
    Import-Module (Join-Path $PSScriptRoot 'Logger.psm1') -Force -Global

    $results = [System.Collections.Generic.List[hashtable]]::new()

    try {
        $url = $Source.BaseUrl
        if ($Category) { $url = "$url?category=$([uri]::EscapeDataString($Category))" }

        Write-Log -Level DEBUG -Category IBM -Message "Fetching list from $url"
        $resp = $HttpClient.GetAsync($url).Result
        if (-not $resp.IsSuccessStatusCode) {
            Write-Log -Level WARN -Category IBM -Message "Source $($Source.Id) returned $($resp.StatusCode)"
            return $results
        }

        $html = $resp.Content.ReadAsStringAsync().Result

        # Lightweight regex link extraction — sufficient for structured IBM pages
        # shortcut: no HTML parser; misses JS-rendered links, upgrade to HtmlAgilityPack if needed
        $pattern = 'href=["\'](?<url>https?://[^"'']+\.(?:pdf|html|htm))["\']'
        $matches  = [regex]::Matches($html, $pattern, 'IgnoreCase')

        foreach ($m in $matches) {
            $docUrl = $m.Groups['url'].Value
            # Try to extract title from nearby text (crude heuristic)
            $titleMatch = [regex]::Match($html, "(?i)<a[^>]+href=[""']$([regex]::Escape($docUrl))[""'][^>]*>([^<]+)</a>")
            $title = if ($titleMatch.Success) { $titleMatch.Groups[1].Value.Trim() } else { Split-Path $docUrl -Leaf }

            $results.Add(@{
                Title       = $title
                Url         = $docUrl
                Category    = $Source.Category
                Subcategory = ''
                Product     = ''
                ContentType = if ($docUrl -match '\.pdf$') { 'PDF' } else { 'HTML' }
                PublishDate = $null
            })
        }

        Write-Log -Level INFO -Category IBM -Message "Found $($results.Count) documents from $($Source.Id)"
    }
    catch {
        Write-Log -Level ERROR -Category IBM -Message "Failed fetching $($Source.Id): $($_.Exception.Message)"
    }

    return $results
}

function Get-IbmDocumentContent {
    <#
    .SYNOPSIS  Download raw bytes of a document URL. Returns @{ Bytes; ContentType }.
    #>
    param(
        [System.Net.Http.HttpClient]$HttpClient,
        [string]$Url
    )
    Import-Module (Join-Path $PSScriptRoot 'Logger.psm1') -Force -Global

    try {
        $resp = $HttpClient.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseContentRead).Result
        $resp.EnsureSuccessStatusCode() | Out-Null
        $bytes = $resp.Content.ReadAsByteArrayAsync().Result
        $ct    = $resp.Content.Headers.ContentType?.MediaType ?? 'application/octet-stream'
        Write-Log -Level DEBUG -Category IBM -Message "Downloaded $($bytes.Length) bytes from $Url"
        return @{ Bytes = $bytes; ContentType = $ct }
    }
    catch {
        Write-Log -Level ERROR -Category IBM -Message "Download failed for $Url : $($_.Exception.Message)"
        return $null
    }
}

Export-ModuleMember -Function Get-IbmSources, Get-IbmDocumentList, Get-IbmDocumentContent
