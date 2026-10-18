# AuthManager.psm1 — manage IBMid + Microsoft (MSAL device-flow) login state
# Tokens are kept ONLY in memory; never written to disk or logs.

$script:IbmSession   = $null   # stores HttpClient/CookieContainer after IBM login
$script:MsalToken    = $null   # in-memory Microsoft access token

# ---------- IBM ----------

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    $b64 = [Convert]::ToBase64String($Bytes)
    return $b64.Split('=')[0].Replace('+', '-').Replace('/', '_')
}

function Get-PkceChallenge {
    param([string]$CodeVerifier)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $verifierBytes = [System.Text.Encoding]::UTF8.GetBytes($CodeVerifier)
    $challengeBytes = $sha.ComputeHash($verifierBytes)
    return ConvertTo-Base64Url $challengeBytes
}

function Invoke-IbmLoginSSO {
    <#
    .SYNOPSIS  Interactive IBM SSO login via IBMid OIDC authorization code flow + PKCE.
    Returns $true on success, $false on failure.
    #>
    param(
        [string]$ClientId = "ibm-doc-collector",
        [string]$RedirectUri = "http://localhost:18080/",
        [string]$AuthorizeBaseUrl = "https://login.ibm.com/authorize",
        [string]$TokenUrl = "https://login.ibm.com/token",
        [switch]$NoBrowser
    )
    Import-Module (Join-Path $PSScriptRoot 'Logger.psm1') -Force -Global

    # Ensure TLS 1.2+ is enabled
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    } catch {}

    # Generate PKCE verifier and challenge
    $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    $bytes = [byte[]]::new(32)
    $rng.GetBytes($bytes)
    $code_verifier = ConvertTo-Base64Url $bytes
    $code_challenge = Get-PkceChallenge $code_verifier

    # Generate state
    $state = [Guid]::NewGuid().ToString("N")

    # Bind the listener first (before opening the browser) so we know the real port.
    # We try ports 18080-18099 and keep the first listener that binds successfully.
    # shortcut: all 20 ports busy → login fails, upgrade: widen range or use ephemeral port.
    $listener        = $null
    $activeRedirectUri = $null

    if ($PSBoundParameters.ContainsKey('RedirectUri')) {
        # Caller supplied an explicit URI — IBM does exact-string matching, so force localhost.
        $activeRedirectUri = $RedirectUri -replace '//127\.0\.0\.1(?=[:/])', '//localhost'
        if ($activeRedirectUri -ne $RedirectUri) {
            Write-Log -Level WARN -Category Auth -Message "Rewrote redirect URI $RedirectUri -> $activeRedirectUri (IBM requires localhost)"
        }
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($activeRedirectUri)
        try {
            $listener.Start()
            Write-Log -Level INFO -Category Auth -Message "HTTP listener started on $activeRedirectUri"
        } catch {
            $listener.Close()
            $listener = $null
            Write-Log -Level ERROR -Category Auth -Message "Failed to start listener on ${activeRedirectUri}: $($_.Exception.Message)"
            Write-Host "Error: Could not start local HTTP listener on ${activeRedirectUri}: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    } else {
        foreach ($port in 18080..18099) {
            $candidate = "http://localhost:${port}/"
            $probe = [System.Net.HttpListener]::new()
            $probe.Prefixes.Add($candidate)
            try {
                $probe.Start()
                # Bind succeeded — keep this listener alive for the callback.
                $listener          = $probe
                $activeRedirectUri = $candidate
                Write-Log -Level INFO -Category Auth -Message "HTTP listener started on $activeRedirectUri"
                break
            } catch {
                $probe.Close()
                Write-Log -Level INFO -Category Auth -Message "Port $port unavailable: $($_.Exception.Message)"
            }
        }
        if (-not $listener) {
            Write-Log -Level ERROR -Category Auth -Message "No free port found in range 18080-18099."
            Write-Host "Error: Could not bind to any port in range 18080-18099. Free a port or check local security software." -ForegroundColor Red
            return $false
        }
    }

    # redirect_uri must be appended raw (not percent-encoded) so IBM compares the plain URI
    # against its registered list; double-encoding causes 'not authorized' rejections.
    $authorizeUrl = "${AuthorizeBaseUrl}?response_type=code&client_id=${ClientId}&redirect_uri=${activeRedirectUri}&state=${state}&code_challenge=${code_challenge}&code_challenge_method=S256&scope=openid"

    try {
        # Open browser
        Write-Host "Opening browser for IBM SSO Login..." -ForegroundColor Cyan
        Write-Host "If the browser does not open automatically, navigate to:" -ForegroundColor Gray
        Write-Host $authorizeUrl -ForegroundColor Gray
        if (-not $NoBrowser) {
            try {
                Start-Process $authorizeUrl
            } catch {
                [System.Diagnostics.Process]::Start($authorizeUrl) | Out-Null
            }
        }

        Write-Host "Waiting for authentication callback on $activeRedirectUri ..." -ForegroundColor Yellow
        Write-Log -Level INFO -Category Auth -Message "Awaiting callback on $activeRedirectUri"
        # Ignore stray requests (favicon, prefetch) that carry no code/error; they caused false 'State mismatch'.
        do {
            $context = $listener.GetContext()
            $request = $context.Request
            $response = $context.Response
            Write-Log -Level INFO -Category Auth -Message "Request received: $($request.Url.AbsolutePath)"
            $isCallback = $request.QueryString["code"] -or $request.QueryString["error"]
            if (-not $isCallback) {
                $response.StatusCode = 404
                $response.Close()
            }
        } until ($isCallback)

        $code          = $request.QueryString["code"]
        $returnedState = $request.QueryString["state"]
        $asError       = $request.QueryString["error"]
        $asErrorDesc   = $request.QueryString["error_description"]

        # Surface any AS-returned error immediately
        if ($asError) {
            $errorMsg = "Authorization server error: $asError - $asErrorDesc"
            Write-Log -Level ERROR -Category Auth -Message $errorMsg
            $errorInfo = "$asError" + ": " + "$asErrorDesc"
            $html = "<html><body><h2>Login failed</h2><p>$errorInfo</p><p>You may close this window.</p></body></html>"
            $response.StatusCode = 400
            $response.ContentType = "text/html"
            $responseBuffer = [System.Text.Encoding]::UTF8.GetBytes($html)
            $response.ContentLength64 = $responseBuffer.Length
            $response.OutputStream.Write($responseBuffer, 0, $responseBuffer.Length)
            $response.OutputStream.Close()
            return $false
        }

        # Validate state
        if ($returnedState -ne $state) {
            $errorMsg = "State mismatch! Expected '$state', got '$returnedState'"
            Write-Log -Level ERROR -Category Auth -Message $errorMsg
            $response.StatusCode = 400
            $response.ContentType = "text/html"
            $responseBuffer = [System.Text.Encoding]::UTF8.GetBytes("<html><body><h2>Error: State mismatch</h2><p>You may close this window.</p></body></html>")
            $response.ContentLength64 = $responseBuffer.Length
            $response.OutputStream.Write($responseBuffer, 0, $responseBuffer.Length)
            $response.OutputStream.Close()
            return $false
        }

        # Tell the browser the handoff is done
        $response.StatusCode = 200
        $response.ContentType = "text/html"
        $html = "<html><body><h2>Login successful</h2><p>You may close this window and return to the CLI.</p></body></html>"
        $responseBuffer = [System.Text.Encoding]::UTF8.GetBytes($html)
        $response.ContentLength64 = $responseBuffer.Length
        $response.OutputStream.Write($responseBuffer, 0, $responseBuffer.Length)
        $response.OutputStream.Close()
    }
    finally {
        if ($null -ne $listener) {
            $listener.Close()
        }
    }

    # Exchange code for tokens
    if ([string]::IsNullOrEmpty($code)) {
        Write-Log -Level ERROR -Category Auth -Message "No authorization code returned from callback."
        return $false
    }

    Write-Host "Exchanging authorization code for tokens..." -ForegroundColor Cyan
    try {
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.CookieContainer = [System.Net.CookieContainer]::new()
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.DefaultRequestHeaders.Add('User-Agent', 'ibm-doc-collector/1.0')

        $body = [System.Collections.Generic.Dictionary[string,string]]::new()
        $body["grant_type"] = "authorization_code"
        $body["client_id"] = $ClientId
        $body["code"] = $code
        $body["redirect_uri"] = $activeRedirectUri
        $body["code_verifier"] = $code_verifier

        $content = [System.Net.Http.FormUrlEncodedContent]::new($body)
        $tokenResp = $client.PostAsync($TokenUrl, $content).Result

        if (-not $tokenResp.IsSuccessStatusCode) {
            $errorDetails = $tokenResp.Content.ReadAsStringAsync().Result
            Write-Log -Level ERROR -Category Auth -Message "Token exchange failed: HTTP $($tokenResp.StatusCode) - $errorDetails"
            return $false
        }

        $tokenJson = $tokenResp.Content.ReadAsStringAsync().Result
        $tokenData = $tokenJson | ConvertFrom-Json
        $accessToken = $tokenData.access_token

        if (-not $accessToken) {
            Write-Log -Level ERROR -Category Auth -Message "Token response did not contain an access_token."
            return $false
        }

        # Set Bearer auth header so all subsequent requests made by this client are authorized
        $client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $accessToken)
        $script:IbmSession = @{
            Client = $client
            Handler = $handler
            AccessToken = $accessToken
            IdToken = $tokenData.id_token
        }
        Write-Log -Level INFO -Category Auth -Message "IBM SSO login succeeded."
        return $true
    }
    catch {
        Write-Log -Level ERROR -Category Auth -Message "Token exchange exception: $($_.Exception.Message)"
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

Export-ModuleMember -Function Invoke-IbmLoginSSO, Test-IbmAuthenticated, Get-IbmHttpClient, Clear-IbmSession,
                               Invoke-MicrosoftLogin, Test-MicrosoftAuthenticated, Get-MicrosoftAccessToken, Clear-MicrosoftSession,
                               ConvertTo-Base64Url, Get-PkceChallenge
