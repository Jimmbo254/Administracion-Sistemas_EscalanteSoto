function Validar-IP ($ip) {
	if ($ip -eq "0.0.0.0" -or $ip -eq "255.255.255.255" -or $ip -eq "127.0.0.1") { return $false }
	return $ip -match "^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"
}

function IP-A-Numero ($ip) {
    $octetos = $ip.Split('.')
    return [double]($octetos[0]) * [math]::Pow(256, 3) + [double]($octetos[1]) * [math]::Pow(256, 2) + [double]($octetos[2]) * 256 + [double]($octetos[3])
}

function Menu-DHCP {
    Clear-Host
    Write-Host " ===  Servicio DHCP Windows ===" -ForegroundColor Cyan
    Write-Host "1) Verificar status DHCP"
    Write-Host "2) Instalar/Desinstalar"
    Write-Host "3) Configurar Servidor"
    Write-Host "4) Monitorear "
    Write-Host "5) Salir"
    return Read-Host "`nSeleccione una opcion"
}

do {
    $opcion = Menu-DHCP
    switch ($opcion) {
        "1" {
            $status = Get-WindowsFeature DHCP
            Write-Host "`nEstado Instalacion: $($status.InstallState)" -ForegroundColor Yellow
            Pause
        }
        "2" {
            $status = Get-WindowsFeature DHCP
            $accion = Read-Host "'I' para Instalar o 'D' para Desinstalar"
            if ($accion -eq 'I') {
                if ($status.InstallState -eq "Installed") { Write-Host "Ya instalado." -ForegroundColor Yellow }
                else { Install-WindowsFeature DHCP -IncludeManagementTools }
            }
            elseif ($accion -eq 'D') { Uninstall-WindowsFeature DHCP -IncludeManagementTools }
            Pause
        }
        "3" {
        }
        "4" {
            Get-DhcpServerv4Scope | ForEach-Object {
                Write-Host "Red: $($_.ScopeId)" -ForegroundColor Yellow
                Get-DhcpServerv4Lease -ScopeId $_.ScopeId | Select-Object IPAddress, HostName, LeaseExpiryTime | Format-Table -AutoSize
            }
            Pause
        }
    }
} while ($opcion -ne "5")
