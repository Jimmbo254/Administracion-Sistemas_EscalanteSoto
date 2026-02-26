# dns_windows.ps1 - Servicio DNS

. ".\funciones_windows.ps1"

# FUNCIONES DNS

function Verificar-DNS {
    Write-Host ""
    Write-Host "=== Verificar instalacion DNS ==="
    if (Rol-Instalado "DNS") {
        Write-Host "[OK] DNS service esta instalado" -ForegroundColor Green
        $svc = Get-Service -Name DNS -ErrorAction SilentlyContinue
        if ($svc.Status -eq "Running") {
            Write-Host "[OK] Servicio DNS RUNNING." -ForegroundColor Green
        } else {
            Write-Host "[Error] Servicio DNS no esta corriendo." -ForegroundColor Red
        }
    } else {
        Write-Host "[Error] DNS service NO esta instalado" -ForegroundColor Red
    }
    Pause
}

function Instalar-DNS {
    Write-Host ""
    Write-Host "==== Instalando dependencias DNS ===="
    Instalar-Rol "DNS"

    Set-Service -Name DNS -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name DNS -ErrorAction SilentlyContinue

    # Abrir puerto DNS en firewall
    $regla = Get-NetFirewallRule -DisplayName "DNS" -ErrorAction SilentlyContinue
    if (-not $regla) {
        New-NetFirewallRule -DisplayName "DNS" -Direction Inbound -Protocol UDP -LocalPort 53 -Action Allow | Out-Null
        New-NetFirewallRule -DisplayName "DNS" -Direction Inbound -Protocol TCP -LocalPort 53 -Action Allow | Out-Null
        Write-Host "[OK] Puerto DNS abierto en firewall." -ForegroundColor Green
    }

    $svc = Get-Service -Name DNS -ErrorAction SilentlyContinue
    if ($svc.Status -eq "Running") {
        Write-Host "[OK] Servicio DNS RUNNING." -ForegroundColor Green
    } else {
        Write-Host "[ERROR] Servicio DNS no esta corriendo." -ForegroundColor Red
    }
    Pause
}

function Listar-Dominios {
    Write-Host ""
    Write-Host "=== Dominios configurados ==="
    try {
        $zonas = Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated -and $_.ZoneType -eq "Primary" }
        if ($zonas) {
            foreach ($zona in $zonas) {
                Write-Host "  - $($zona.ZoneName)"
            }
        } else {
            Write-Host "No se encontraron dominios configurados."
        }
    } catch {
        Write-Host "[Error] No se pudo obtener la lista de zonas." -ForegroundColor Red
    }
    Pause
}

function Agregar-Dominio {
    Write-Host ""
    Write-Host "=== Agregar nuevo dominio ==="
    if (-not (Rol-Instalado "DNS")) {
        Write-Host "[Error] Instale el servicio primero." -ForegroundColor Red
        Pause; return
    }

    $dominio = Read-Host "Nombre del dominio (ej: empresa.local)"
    while ([string]::IsNullOrWhiteSpace($dominio)) {
        Write-Host "[Error] El dominio no puede estar vacio." -ForegroundColor Red
        $dominio = Read-Host "Nombre del dominio"
    }

    # Obtener IP del adaptador activo como default
    $interfaz = Get-NetAdapter | Where-Object Name -like '*Ethernet 2*' | Select-Object -First 1
    if (-not $interfaz) {
        $interfaz = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
    }
    $ipAuto = (Get-NetIPAddress -InterfaceAlias $interfaz.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress

    $ip_input = Read-Host "IP para el dominio [Enter = $ipAuto]"
    if ([string]::IsNullOrWhiteSpace($ip_input)) {
        $ip_dominio = $ipAuto
        Write-Host "Usando IP: $ip_dominio" -ForegroundColor Cyan
    } else {
        if (-not (Validar-IP $ip_input)) {
            Write-Host "[Error] IP no valida." -ForegroundColor Red
            Pause; return
        }
        $ip_dominio = $ip_input
    }

    try {
        $zonaExiste = Get-DnsServerZone -Name $dominio -ErrorAction SilentlyContinue
        if (-not $zonaExiste) {
            Write-Host "Creando zona primaria '$dominio'..." -ForegroundColor Yellow
            Add-DnsServerPrimaryZone -Name $dominio -ZoneFile "$dominio.dns" -DynamicUpdate None | Out-Null
            Write-Host "[OK] Zona creada." -ForegroundColor Green
        } else {
            Write-Host "[Aviso] La zona '$dominio' ya existe, agregando registro..." -ForegroundColor Yellow
        }

        Add-DnsServerResourceRecordA -ZoneName $dominio -Name "@"   -IPv4Address $ip_dominio -AllowUpdateAny -ErrorAction SilentlyContinue | Out-Null
        Add-DnsServerResourceRecordA -ZoneName $dominio -Name "ns"  -IPv4Address $ip_dominio -AllowUpdateAny -ErrorAction SilentlyContinue | Out-Null
        Add-DnsServerResourceRecordCName -ZoneName $dominio -Name "www" -HostNameAlias "$dominio." -ErrorAction SilentlyContinue | Out-Null

        Write-Host ""
        Write-Host "[OK] Dominio '$dominio' agregado y apuntando a '$ip_dominio'." -ForegroundColor Green

        # Prueba rapida con nslookup
        Write-Host "`nHaciendo prueba rapida:" -ForegroundColor Cyan
        nslookup $dominio "127.0.0.1"

    } catch {
        Write-Host ""
        Write-Host "[ERROR] Problema al configurar la zona: $($_.Exception.Message)" -ForegroundColor Red
    }
    Pause
}

function Eliminar-Dominio {
    Write-Host ""
    Write-Host "=== Eliminar dominio ==="
    if (-not (Rol-Instalado "DNS")) {
        Write-Host "[Error] Instale el servicio primero." -ForegroundColor Red
        Pause; return
    }

    $zonas = Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated -and $_.ZoneType -eq "Primary" }
    if (-not $zonas) {
        Write-Host "No hay dominios para eliminar."
        Pause; return
    }

    Write-Host "Dominios configurados:"
    foreach ($zona in $zonas) {
        Write-Host "  - $($zona.ZoneName)"
    }

    $dominio = Read-Host "Ingresa el nombre del dominio a eliminar"

    $zonaExiste = Get-DnsServerZone -Name $dominio -ErrorAction SilentlyContinue
    if (-not $zonaExiste) {
        Write-Host "[Error] El dominio '$dominio' no existe." -ForegroundColor Red
        Pause; return
    }

    $conf = Read-Host "¿Confirmar eliminacion de '$dominio'? (s/N)"
    if ($conf -ne 's' -and $conf -ne 'S') {
        Write-Host "Cancelado."
        Pause; return
    }

    try {
        Remove-DnsServerZone -Name $dominio -Force
        Write-Host "[OK] Dominio '$dominio' eliminado." -ForegroundColor Green
    } catch {
        Write-Host "[Error] $($_.Exception.Message)" -ForegroundColor Red
    }
    Pause
}

# MENU MAIN

Verificar-Administrador

function Menu-DNS {
    Clear-Host
    Write-Host "========= MENÚ DNS =========" -ForegroundColor Cyan
    Write-Host "1) Verificar instalacion"
    Write-Host "2) Instalar dependencias"
    Write-Host "3) Listar Dominios configurados"
    Write-Host "4) Agregar nuevo dominio"
    Write-Host "5) Eliminar un dominio"
    Write-Host "6) Salir"
    Write-Host "============================="
    return Read-Host "`nSelecciona una opcion"
}

do {
    $opcion = Menu-DNS
    switch ($opcion) {
        "1" { Verificar-DNS    }
        "2" { Instalar-DNS     }
        "3" { Listar-Dominios  }
        "4" { Agregar-Dominio  }
        "5" { Eliminar-Dominio }
    }
} while ($opcion -ne "6")
