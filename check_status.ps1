Clear-Host
Write-Host "--- ESTADO DEL SISTEMA ---"
Write-Host "Equipo: $env:COMPUTERNAME"
Write-Host "IPs:"
Get-NetIPAddress -AddressFamily IPv4 | Select-Object IPAddress
$disco = Get-PSDrive C
Write-Host "Disco C: Libre $([Math]::Round($disco.Free/1GB,2)) GB"