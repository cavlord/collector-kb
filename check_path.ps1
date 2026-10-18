$path = $env:PATH
$parts = $path -split ';'
Write-Host "=== First 10 PATH entries ==="
for ($i = 0; $i -lt $parts.Length; $i++) {
    Write-Host "[$i]: $($parts[$i])"
}
Write-Host "=== Check for ibmi-doc ==="
$parts | Where-Object { $_ -like '*ibmi-doc*' } | Select-Object -First 5
