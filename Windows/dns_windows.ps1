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
}

function Agregar-Dominio {
    Write-Host ""
    Write-Host "=== Agregar nuevo dominio ==="
}

function Eliminar-Dominio {
    Write-Host ""
    Write-Host "=== Eliminar dominio ==="
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
