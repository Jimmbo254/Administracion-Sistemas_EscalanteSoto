# ssh_windows.ps1 - Servicio SSH windows

. ".\funciones_windows.ps1"

function Revision-SSH {
    Write-Host ""
    Write-Host "=== Verificar instalacion SSH ==="
    $ssh = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'
    if ($ssh.State -eq "Installed") {
        Write-Host "[OK] OpenSSH esta instalado." -ForegroundColor Green
    } else {
        Write-Host "[Error] OpenSSH NO esta instalado." -ForegroundColor Red
    }

    $servicio = Get-Service sshd -ErrorAction SilentlyContinue
    if ($servicio -and $servicio.Status -eq "Running") {
        Write-Host "[OK] Servicio ACTIVO." -ForegroundColor Green
    } else {
        Write-Host "[Error] Servicio NO activo." -ForegroundColor Red
    }

    if ($servicio -and $servicio.StartType -eq "Automatic") {
        Write-Host "[OK] Servicio habilitado en boot." -ForegroundColor Green
    } else {
        Write-Host "[Error] Servicio NO habilitado en boot." -ForegroundColor Red
    }
    Pause
}

function Instalar-SSH {
    Write-Host ""
    Write-Host "==== Instalando dependencias SSH ===="
    $ssh = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'
    if ($ssh.State -ne "Installed") {
        Write-Host "Instalando OpenSSH Server..." -ForegroundColor Yellow
        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
        Write-Host "[OK] OpenSSH instalado." -ForegroundColor Green
    } else {
        Write-Host "[OK] OpenSSH ya estaba instalado." -ForegroundColor Green
    }

    Start-Service sshd
    Set-Service -Name sshd -StartupType Automatic

    if (!(Get-NetFirewallRule -Name "sshd" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name sshd `
            -DisplayName "OpenSSH Server (sshd)" `
            -Enabled True `
            -Direction Inbound `
            -Protocol TCP `
            -Action Allow `
            -LocalPort 22 | Out-Null
        Write-Host "[OK] Puerto 22 abierto en firewall." -ForegroundColor Green
    }

    $servicio = Get-Service sshd -ErrorAction SilentlyContinue
    if ($servicio -and $servicio.Status -eq "Running") {
        Write-Host "[OK] SSH configurado correctamente." -ForegroundColor Green
    } else {
        Write-Host "[ERROR] SSH no pudo iniciarse." -ForegroundColor Red
    }
    Pause
}

function Desinstalar-SSH {
    Write-Host ""
    Write-Host "=== Desinstalar SSH ==="
    Write-Host "ATENCION: Desinstalar SSH cortara el acceso remoto." -ForegroundColor Yellow
    $conf = Read-Host "Escribe 'confirmar' para continuar"
    if ($conf -ne "confirmar") {
        Write-Host "Cancelado."
        Pause; return
    }

    Stop-Service sshd -ErrorAction SilentlyContinue
    Set-Service -Name sshd -StartupType Disabled -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -Name sshd -ErrorAction SilentlyContinue
    Remove-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
    Write-Host "[OK] OpenSSH eliminado." -ForegroundColor Green
    Pause
}

# ====== menu main =======

Verificar-Administrador

function Menu-SSH {
	Clear-Host
	Write-Host "====== MENU SSH ======" -ForegroundColor Cyan
	Write-Host "1) Verificar instalacion"
    Write-Host "2) Instalar dependencias"
    Write-Host "3) Desinstalar"
    Write-Host "4) Salir"
    Write-Host "============================="
    return Read-Host "`nSelecciona una opcion"
}

do {
    $opcion = Menu-SSH
    switch ($opcion) {
        "1" { Revision-SSH    }
        "2" { Instalar-SSH    }
        "3" { Desinstalar-SSH }
    }
} while ($opcion -ne "4")
