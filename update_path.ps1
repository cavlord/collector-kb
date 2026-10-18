$bin = 'C:\Users\FAHMIRAHMADI\AppData\Local\ibmi-doc-collector\bin'
$currentPath = $env:PATH
if ($currentPath -notlike "*$bin*") {
    $newPath = "$bin;$currentPath"
    [Environment]::SetEnvironmentVariable('PATH', $newPath, [EnvironmentVariableTarget]::User)
    Write-Host 'PATH updated'
} else {
    Write-Host 'PATH already contains bin'
}
