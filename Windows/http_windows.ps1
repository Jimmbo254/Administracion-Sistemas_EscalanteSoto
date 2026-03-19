# http_windows.ps1 — Servidor Web Windows Server (Main)

. ".\http_functions.ps1"

function Test-Admin {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($current)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host ""
    Write-Host "  ERROR: Ejecuta este script como Administrador." -ForegroundColor Red
    Write-Host "  Clic derecho -> Ejecutar con PowerShell como Administrador" -ForegroundColor Yellow
    Write-Host ""
    pause
    exit 1
}

while ($true) {
    Clear-Host
    Write-Host ""
    Write-Host "========= MENÚ HTTP =========" -ForegroundColor Cyan
    Write-Host "1) Instalar IIS"
    Write-Host "2) Instalar Apache (httpd)"
    Write-Host "3) Instalar Nginx"
    Write-Host "4) Instalar Tomcat"
    Write-Host "5) Verificar servicio activo"
    Write-Host "6) Desinstalar servidor"
    Write-Host "7) Levantar/Reiniciar servicio"
    Write-Host "8) Limpiar entorno"
    Write-Host "0) Salir"
    Write-Host "============================="
    Write-Host ""

    $opcion = Read-Host "  Opcion"

    switch ($opcion) {
        "1" { Flujo-Instalacion -tipo "iis"    -nombre "IIS"            }
        "2" { Flujo-Instalacion -tipo "apache" -nombre "Apache (httpd)" }
        "3" { Flujo-Instalacion -tipo "nginx"  -nombre "Nginx"          }
        "4" { Flujo-Instalacion -tipo "tomcat" -nombre "Tomcat"         }
        "5" { Flujo-Verificacion                                        }
        "6" { Desinstalar-Servidor                                      }
        "7" { Levantar-Servicio                                         }
        "8" {
            $conf = Read-Host "  Seguro que deseas purgar todos los servidores? [s/N]"
            if ($conf -match '^[sS]$') { Limpiar-Entorno }
        }
        "0" {
            Write-Host ""; Write-Host "  Cerrando..." -ForegroundColor Cyan
            Write-Host ""; exit 0
        }
        default { Write-Host "  Opcion invalida." -ForegroundColor Red }
    }

    Write-Host ""
    Read-Host "  Presiona ENTER para volver al menu"
}
