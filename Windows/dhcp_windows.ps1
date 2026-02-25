# dhcp_windows.ps1 — Servicio DHCP

. ".\funciones_windows.ps1"

# ============================================================
# FUNCIONES DHCP
# ============================================================

function Verificar-StatusDHCP {
    $status = Get-WindowsFeature DHCP
    Write-Host "`nEstado Instalacion: $($status.InstallState)" -ForegroundColor Yellow
    Pause
}

function Instalar-DesinstalarDHCP {
    $accion = Read-Host "'I' para Instalar o 'D' para Desinstalar"
    if ($accion -eq 'I') {
        Instalar-Rol "DHCP"
    } elseif ($accion -eq 'D') {
        Desinstalar-Rol "DHCP"
    } else {
        Write-Host "Opcion no valida." -ForegroundColor Red
    }
    Pause
}

function Configurar-ServidorDHCP {
    if (-not (Rol-Instalado "DHCP")) {
        Write-Host "Error: Instale el servicio primero." -ForegroundColor Red
        Pause; return
    }

    $nombreAmbito = Read-Host "Nombre del nuevo Ambito"
    do { $ipServer = Read-Host "IP Inicial (Servidor)" } until (Validar-IP $ipServer)

    $partes = $ipServer.Split('.')
    $primerOcteto = [int]$partes[0]
    if ($primerOcteto -le 126)     { $mascara = "255.0.0.0";    $prefix = 8  }
    elseif ($primerOcteto -le 191) { $mascara = "255.255.0.0";  $prefix = 16 }
    else                           { $mascara = "255.255.255.0"; $prefix = 24 }

    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
    if ($adapter) {
        $adapter | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        $adapter | New-NetIPAddress -IPAddress $ipServer -PrefixLength $prefix -ErrorAction SilentlyContinue | Out-Null
        Write-Host "Servidor configurado en $ipServer" -ForegroundColor Green
    }

    $ipInicio  = "$($partes[0]).$($partes[1]).$($partes[2]).$([int]$partes[3] + 1)"
    $numInicio = IP-A-Numero $ipInicio
    $numServer = IP-A-Numero $ipServer

    do {
        $ipFinal = Read-Host "IP Final del rango para clientes"
        $valido  = (Validar-IP $ipFinal)
        if ($valido) {
            $numFinal = IP-A-Numero $ipFinal
            if ($numFinal -eq $numServer) {
                Write-Host "Error: La IP final no puede ser la misma IP del Servidor ($ipServer)." -ForegroundColor Red
                $valido = $false
            } elseif ($numFinal -lt $numInicio) {
                Write-Host "Error: La IP final ($ipFinal) debe ser MAYOR a la inicial ($ipInicio)." -ForegroundColor Red
                $valido = $false
            }
        }
    } until ($valido)

    do {
        $secInput = Read-Host "Lease Time (segundos)"
        if ($secInput -match "^\d+$" -and [int]$secInput -gt 0) {
            $leaseSec  = [int]$secInput
            $validoSec = $true
        } else {
            Write-Host "Error: Ingrese un numero entero de segundos valido." -ForegroundColor Red
            $validoSec = $false
        }
    } until ($validoSec)

    $gw  = Read-Host "Gateway (Enter para saltar)"
    $dns = Read-Host "DNS (Enter para saltar)"

    try {
        Add-DhcpServerv4Scope -Name $nombreAmbito -StartRange $ipInicio -EndRange $ipFinal `
            -SubnetMask $mascara -LeaseDuration ([TimeSpan]::FromSeconds($leaseSec)) | Out-Null
        if ($gw)  { Set-DhcpServerv4OptionValue -Router    $gw  -Force | Out-Null }
        if ($dns) { Set-DhcpServerv4OptionValue -DnsServer $dns -Force | Out-Null }
        Write-Host "Ambito '$nombreAmbito' activado exitosamente." -ForegroundColor Green
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    Pause
}

function Monitorear-DHCP {
    Get-DhcpServerv4Scope | ForEach-Object {
        Write-Host "Red: $($_.ScopeId)" -ForegroundColor Yellow
        Get-DhcpServerv4Lease -ScopeId $_.ScopeId |
            Select-Object IPAddress, HostName, LeaseExpiryTime |
            Format-Table -AutoSize
    }
    Pause
}

# ============================================================
# MAIN
# ============================================================

Verificar-Administrador

function Menu-DHCP {
    Clear-Host
    Write-Host " === Servicio DHCP Windows ===" -ForegroundColor Cyan
    Write-Host "1) Verificar status DHCP"
    Write-Host "2) Instalar/Desinstalar"
    Write-Host "3) Configurar Servidor"
    Write-Host "4) Monitorear"
    Write-Host "5) Salir"
    return Read-Host "`nSeleccione una opcion"
}

do {
    $opcion = Menu-DHCP
    switch ($opcion) {
        "1" { Verificar-StatusDHCP     }
        "2" { Instalar-DesinstalarDHCP }
        "3" { Configurar-ServidorDHCP  }
        "4" { Monitorear-DHCP          }
    }
} while ($opcion -ne "5")
