# AuthManager.psm1 — manage IBMid + Microsoft (MSAL device-flow) login state
# Tokens are kept ONLY in memory; never written to disk or logs.

$script:IbmSession   = $null   # stores HttpClient/CookieContainer after IBM login
$script:MsalToken    = $null   # in-memory Microsoft access token

# ---------- IBM ----------

function Invoke-IbmLogin {
    <#
    .SYNOPSIS  Interactive IBM w3id / IBMid login via headless form post.
    Returns $true on success, $false on failure.
    #>
    param(
        [string]$Username,
        [securestring]$Password
    )
    Import-Module (Join-Path $PSScriptRoot 'Logger.psm1') -Force -Global

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.CookieContainer = [System.Net.CookieContainer]::new()
    $handler.AllowAutoRedirect = $true

    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.DefaultRequestHeaders.Add('User-Agent', 'ibm-doc-collector/1.0')

    try {
        # Discover login endpoint from IBM Support homepage
        $loginUrl = 'https://myibm.ibm.com/dashboard/'
        $resp = $client.GetAsync($loginUrl).Result
        $resp.EnsureSuccessStatusCode() | Out-Null

        # Authenticate with IBMid (OIDC form post)
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

        $body = [System.Collections.Generic.Dictionary[string,string]]::new()
        $body['j_username'] = $Username
        $body['j_password'] = $plain
        $plain = $null   # clear from memory ASAP

        $content = [System.Net.Http.FormUrlEncodedContent]::new($body)
        $authUrl  = 'https://idaas.iam.ibm.com/pkmslogin.form'
        $authResp  = $client.PostAsync($authUrl, $content).Result

        if ($authResp.IsSuccessStatusCode -or $authResp.StatusCode -eq 302) {
            $script:IbmSession = @{ Client = $client; Handler = $handler }
            Write-Log -Level INFO -Category Auth -Message "IBM login succeeded for $Username"
            return $true
        }
        Write-Log -Level ERROR -Category Auth -Message "IBM login failed: HTTP $($authResp.StatusCode)"
        return $false
    }
    catch {
        Write-Log -Level ERROR -Category Auth -Message "IBM login exception: $($_.Exception.Message)"
        return $false
    }
}

function Test-IbmAuthenticated {
    return ($null -ne $script:IbmSession)
}

function Get-IbmHttpClient {
    if (-not $script:IbmSession) { throw "IBM session not authenticated. Run: ibm-doc-collector auth ibm" }
    return $script:IbmSession.Client
}

function Clear-IbmSession {
    if ($script:IbmSession) {
        $script:IbmSession.Client.Dispose()
        $script:IbmSession = $null
    }
}

# ---------- Microsoft / SharePoint (device-code flow, no secret on disk) ----------

function Invoke-MicrosoftLogin {
    <#
    .SYNOPSIS  MSAL device-code flow. Requires MSAL.PS or Az.Accounts.
    Stores the token object in memory only.
    #>
    param(
        [string]$TenantId,
        [string]$ClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'  # well-known MSAL public client
    )
    Import-Module (Join-Path $PSScriptRoot 'Logger.psm1') -Force -Global

    # Prefer MSAL.PS if available; fall back to Az.Accounts
    if (Get-Module -ListAvailable -Name MSAL.PS) {
        Import-Module MSAL.PS -ErrorAction Stop
        $token = Get-MsalToken -TenantId $TenantId -ClientId $ClientId `
                               -Scopes 'https://graph.microsoft.com/.default' `
                               -DeviceCode
        $script:MsalToken = $token
        Write-Log -Level INFO -Category Auth -Message "Microsoft login succeeded (MSAL.PS) for tenant $TenantId"
        return $true
    }
    elseif (Get-Module -ListAvailable -Name Az.Accounts) {
        Connect-AzAccount -TenantId $TenantId -UseDeviceAuthentication | Out-Null
        $script:MsalToken = @{ TenantId = $TenantId; Source = 'Az' }
        Write-Log -Level INFO -Category Auth -Message "Microsoft login succeeded (Az.Accounts) for tenant $TenantId"
        return $true
    }
    else {
        Write-Log -Level ERROR -Category Auth -Message "No MSAL provider found. Install MSAL.PS: Install-Module MSAL.PS"
        return $false
    }
}

function Test-MicrosoftAuthenticated {
    return ($null -ne $script:MsalToken)
}

function Get-MicrosoftAccessToken {
    if (-not $script:MsalToken) { throw "Microsoft session not authenticated. Run: ibm-doc-collector auth sharepoint" }

    # Refresh if MSAL.PS token object has ExpiresOn
    if ($script:MsalToken.PSObject.Properties['ExpiresOn']) {
        if ($script:MsalToken.ExpiresOn -le [DateTimeOffset]::UtcNow.AddMinutes(5)) {
            $tenantId  = $script:MsalToken.TenantId
            $clientId  = $script:MsalToken.ClientId
            $script:MsalToken = Get-MsalToken -TenantId $tenantId -ClientId $clientId `
                                               -Scopes 'https://graph.microsoft.com/.default' `
                                               -Silent -ForceRefresh
        }
        return $script:MsalToken.AccessToken
    }
    # Az.Accounts path — get fresh token via context
    return (Get-AzAccessToken -ResourceTypeName MSGraph).Token
}

function Clear-MicrosoftSession {
    $script:MsalToken = $null
}

Export-ModuleMember -Function Invoke-IbmLogin, Test-IbmAuthenticated, Get-IbmHttpClient, Clear-IbmSession,
                               Invoke-MicrosoftLogin, Test-MicrosoftAuthenticated, Get-MicrosoftAccessToken, Clear-MicrosoftSession
