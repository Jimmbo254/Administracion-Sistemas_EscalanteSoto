# http_windows.ps1 — Servidor Web Windows Server (Main)

. "$PSScriptRoot\http_functions.ps1"

function Validar-Admin {
    $current   = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($current)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Validar-Admin)) {
    Write-Host "[Error] Se requieren permisos de Administrador." -ForegroundColor Red
    Write-Host "Clic derecho -> Ejecutar como Administrador" -ForegroundColor Yellow
    Pause; exit 1
}

while ($true) {
    Clear-Host
    Write-Host "========= MENÚ HTTP =========" -ForegroundColor Yellow
    Write-Host "1) Instalar IIS"
    Write-Host "2) Instalar Apache (httpd)"
    Write-Host "3) Instalar Nginx"
    Write-Host "4) Instalar Tomcat"
    Write-Host "5) Verificar servicio"
    Write-Host "6) Desinstalar servidor"
    Write-Host "7) Levantar/Reiniciar servicio"
    Write-Host "8) Limpiar entorno"
    Write-Host "0) Salir"
    Write-Host "============================="
    Write-Host ""

    $opcion = Read-Host "Selecciona una opcion"

    switch ($opcion) {
        "1" { Flujo-Instalar -tipo "iis"    -nombre "IIS"            }
        "2" { Flujo-Instalar -tipo "apache" -nombre "Apache (httpd)" }
        "3" { Flujo-Instalar -tipo "nginx"  -nombre "Nginx"          }
        "4" { Flujo-Instalar -tipo "tomcat" -nombre "Tomcat"         }
        "5" { Flujo-Verificar                                        }
        "6" { Quitar-Servidor                                        }
        "7" { Reiniciar-Servidor                                     }
        "8" {
            $conf = Read-Host "  ¿Confirmar limpieza total del entorno? (s/N)"
            if ($conf -match '^[sS]$') { Limpiar-Entorno }
        }
        "0" { Write-Host "  Cerrando..." -ForegroundColor Cyan; exit 0 }
        default { Write-Host "  [Error] Opcion no valida." -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }

    Write-Host ""
    Read-Host "  Presiona Enter para continuar"
}
