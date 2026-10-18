#Requires -Module Pester

$ModuleDir = Join-Path $PSScriptRoot '..\src\Modules'
Import-Module (Join-Path $ModuleDir 'Logger.psm1')           -Force
Import-Module (Join-Path $ModuleDir 'Config.psm1')           -Force
Import-Module (Join-Path $ModuleDir 'MetadataStore.psm1')    -Force
Import-Module (Join-Path $ModuleDir 'DocumentProcessor.psm1') -Force
Import-Module (Join-Path $ModuleDir 'AuthManager.psm1')      -Force

$script:TestDir = Join-Path $env:TEMP "ibm-doc-collector-test-$(New-Guid)"
if (-not (Test-Path $script:TestDir)) {
    New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
}

# ── Logger ────────────────────────────────────────────────────────────────────
Describe 'Logger' {
    It 'Creates log file and writes entry' {
        Initialize-Logger -LogDir $script:TestDir
        Write-Log -Level INFO -Message 'unit test entry'
        $logPath = Get-LogPath
        $logPath | Should Not BeNullOrEmpty
        (Test-Path $logPath) | Should Be $true
        (Get-Content $logPath) | Should Match 'unit test entry'
    }

    It 'Redacts tokens from log messages' {
        Initialize-Logger -LogDir $script:TestDir
        Write-Log -Level INFO -Message 'token=abc123secret'
        $logPath = Get-LogPath
        $content = Get-Content $logPath -Raw
        $content | Should Not Match 'abc123secret'
        $content | Should Match '\[REDACTED\]'
    }
}

# ── Config ────────────────────────────────────────────────────────────────────
Describe 'Config' {
    It 'Saves and retrieves values' {
        Initialize-Config -ConfigDir $script:TestDir
        Set-Config @{ tenantId = 'test-tenant'; siteId = 'test-site' }
        $cfg = Get-Config
        $cfg['tenantId'] | Should Be 'test-tenant'
        $cfg['siteId']   | Should Be 'test-site'
    }

    It 'Merges new keys without losing existing ones' {
        Initialize-Config -ConfigDir $script:TestDir
        Set-Config @{ tenantId = 'original' }
        Set-Config @{ libraryName = 'Documents' }
        $cfg = Get-Config
        $cfg['tenantId']    | Should Be 'original'
        $cfg['libraryName'] | Should Be 'Documents'
    }
}

# ── MetadataStore ─────────────────────────────────────────────────────────────
Describe 'MetadataStore' {
    BeforeEach {
        $script:MetaDir = Join-Path $script:TestDir "meta-$(New-Guid)"
        Initialize-MetadataStore -DataDir $script:MetaDir
        Initialize-Logger -LogDir $script:MetaDir
    }

    It 'Saves and retrieves a record' {
        Save-Metadata -Judul 'Test Doc' -SourceUrl 'https://example.com/doc1' `
                      -Kategori 'Support' -ContentType 'PDF' -Hash 'AAAA1111'
        $rec = Get-MetadataByUrl -Url 'https://example.com/doc1'
        $rec | Should Not BeNullOrEmpty
        $rec.judul | Should Be 'Test Doc'
        $rec.hash | Should Be 'AAAA1111'
    }

    It 'Skips record when URL and hash are unchanged' {
        Save-Metadata -Judul 'Test Doc' -SourceUrl 'https://example.com/doc2' `
                      -Kategori 'Support' -ContentType 'PDF' -Hash 'BBBB2222'
        $result = Save-Metadata -Judul 'Test Doc' -SourceUrl 'https://example.com/doc2' `
                                -Kategori 'Support' -ContentType 'PDF' -Hash 'BBBB2222'
        $result | Should Be 'skipped'
    }

    It 'Updates record when URL is same but hash changed' {
        Save-Metadata -Judul 'Test Doc' -SourceUrl 'https://example.com/doc3' `
                      -Kategori 'Support' -ContentType 'PDF' -Hash 'CCCC3333'
        $result = Save-Metadata -Judul 'Test Doc' -SourceUrl 'https://example.com/doc3' `
                                -Kategori 'Support' -ContentType 'PDF' -Hash 'DDDD4444'
        $result | Should Be 'updated'
        (Get-MetadataByUrl -Url 'https://example.com/doc3').hash | Should Be 'DDDD4444'
    }

    It 'Marks potential-duplicate when different URL has same hash' {
        Save-Metadata -Judul 'Original' -SourceUrl 'https://example.com/orig' `
                      -Kategori 'Docs' -ContentType 'PDF' -Hash 'EEEEE555'
        $result = Save-Metadata -Judul 'Duplicate' -SourceUrl 'https://example.com/dup' `
                                -Kategori 'Docs' -ContentType 'PDF' -Hash 'EEEEE555'
        $result | Should Be 'potential-duplicate'
    }

    It 'Reports accurate stats' {
        Save-Metadata -Judul 'A' -SourceUrl 'https://example.com/a' -Kategori 'X' -ContentType 'PDF' -Hash 'H1'
        Save-Metadata -Judul 'B' -SourceUrl 'https://example.com/b' -Kategori 'X' -ContentType 'PDF' -Hash 'H2'
        $stats = Get-MetadataStats
        ($stats.Total -ge 2) | Should Be $true
    }
}

# ── DocumentProcessor ─────────────────────────────────────────────────────────
Describe 'DocumentProcessor' {
    It 'Computes SHA-256 hash and saves file' {
        $bytes   = [System.Text.Encoding]::UTF8.GetBytes('hello ibm doc')
        $staging = Join-Path $script:TestDir 'staging'
        Initialize-Logger -LogDir $script:TestDir

        $result = Invoke-ProcessDocument -Bytes $bytes -Url 'https://example.com/test.pdf' `
                                         -ContentType 'application/pdf' -StagingDir $staging
        $result | Should Not BeNullOrEmpty
        $result.Hash | Should Match '^[A-F0-9]{64}$'
        $result.Extension | Should Be '.pdf'
        (Test-Path $result.LocalPath) | Should Be $true
    }

    It 'Returns $null for empty bytes' {
        Initialize-Logger -LogDir $script:TestDir
        $result = Invoke-ProcessDocument -Bytes @() -Url 'https://x.com/empty' `
                                         -ContentType 'text/html' -StagingDir (Join-Path $script:TestDir 'staging2')
        $result | Should BeNullOrEmpty
    }
}

# ── AuthManager PKCE ──────────────────────────────────────────────────────────
Describe 'AuthManager PKCE' {
    It 'Converts bytes to base64url format correctly' {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('foo+bar/baz=')
        $result = ConvertTo-Base64Url $bytes
        $result | Should Not Match '\+'
        $result | Should Not Match '/'
        $result | Should Not Match '='
    }

    It 'Generates correct PKCE S256 challenge' {
        $verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        $challenge = Get-PkceChallenge $verifier
        $challenge | Should Be "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    }

    It 'Invoke-IbmLoginSSO handles callback and state validation' {
        $job = Start-Job -ScriptBlock {
            Start-Sleep -Seconds 1
            try {
                $wc = New-Object System.Net.WebClient
                $wc.DownloadString("http://localhost:18082/?code=mock_code&state=wrong_state") | Out-Null
            } catch {}
        }
        try {
            $ok = Invoke-IbmLoginSSO -NoBrowser -RedirectUri "http://localhost:18082/"
            $ok | Should Be $false
        }
        finally {
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
    }
}

# ── Teardown ──────────────────────────────────────────────────────────────────
Describe 'Teardown' {
    It 'Cleans up temporary directory' {
        Remove-Item -Recurse -Force $script:TestDir -ErrorAction SilentlyContinue
        (Test-Path $script:TestDir) | Should Be $false
    }
}
