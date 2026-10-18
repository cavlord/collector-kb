$uri = 'http://localhost:18080/'
try {
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($uri)
    $listener.Start()
    Write-Host 'Port 18080 is available'
    $listener.Stop()
} catch {
    Write-Host 'Port 18080 is NOT available: ' + $_.Exception.Message
}
