# http_windows.ps1 — Servidor Web Windows Server (Main)

. ".\http_functions.ps1"

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "[!] Ejecuta PowerShell como Administrador."
    Start-Sleep -Seconds 4
    exit
}

do {
    Write-Host ""
    Write-Host "========= MENU HTTP =========" -ForegroundColor Blue
    Write-Host "1) Instalar IIS"
    Write-Host "2) Instalar Apache"
    Write-Host "3) Instalar Nginx"
    Write-Host "4) Desinstalar IIS"
    Write-Host "5) Desinstalar Apache"
    Write-Host "6) Desinstalar Nginx"
    Write-Host "0) Salir"
    Write-Host "============================="
    Write-Host ""

    $opcion = Read-Host "Selecciona una opcion"

    switch ($opcion) {
        "1" { Instalar-IIS     }
        "2" { Instalar-Apache  }
        "3" { Instalar-Nginx   }
        "4" { Desinstalar-IIS  }
        "5" { Desinstalar-Apache }
        "6" { Desinstalar-Nginx  }
        "0" { Write-Host "Cerrando..."; break }
        default { Write-Host "  [Error] Opcion no valida." -ForegroundColor Red }
    }
} while ($opcion -ne "0")
