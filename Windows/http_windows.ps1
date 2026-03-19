# http_windows.ps1 — Servidor Web Windows Server (Main)

. ".\http_functions.ps1"

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "[!] Ejecuta PowerShell como Administrador."
    Start-Sleep -Seconds 4
    exit
}

do {
    Write-Host "`n========= MENU HTTP =========" -ForegroundColor Cyan
    Write-Host "1) Instalar IIS "
    Write-Host "2) Instalar Apache "
    Write-Host "3) Instalar Nginx "
    Write-Host "4) Desinstalar IIS"
    Write-Host "5) Desinstalar Apache"
    Write-Host "6) Desinstalar Nginx"
    Write-Host "0) Salir"
    Write-Host "============================="

    $opcion = Read-Host "Elige una opcion"

    switch ($opcion) {
        "1" { Instalar-IIS }
        "2" { Instalar-Opcional -Servicio "apache" }
        "3" { Instalar-Opcional -Servicio "nginx" }
        "4" { Desinstalar-IIS }
        "5" { Desinstalar-Opcional -Servicio "apache" }
        "6" { Desinstalar-Opcional -Servicio "nginx" }
        "0" { Write-Host "Saliendo..."; break }
        default { Write-Host "[Error] Opcion no valida." -ForegroundColor Red }
    }
} while ($opcion -ne "0")
