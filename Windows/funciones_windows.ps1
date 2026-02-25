# FUNCIONES BASICAS WINDOWS

function Verificar-Administrador {
    if (-not ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Error: Ejecutar como Administrador." -ForegroundColor Red
        exit 1
    }
}

function Validar-IP ($ip) {
    if ($ip -eq "0.0.0.0" -or $ip -eq "255.255.255.255" -or $ip -eq "127.0.0.1") { return $false }
    return $ip -match "^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"
}

function IP-A-Numero ($ip) {
    $octetos = $ip.Split('.')
    return [double]($octetos[0]) * [math]::Pow(256, 3) + `
           [double]($octetos[1]) * [math]::Pow(256, 2) + `
           [double]($octetos[2]) * 256 + `
           [double]($octetos[3])
}

function Rol-Instalado ($rol) {
    return (Get-WindowsFeature $rol).InstallState -eq "Installed"
}

function Instalar-Rol ($rol) {
    if (Rol-Instalado $rol) {
        Write-Host "$rol ya esta instalado." -ForegroundColor Yellow
    } else {
        Write-Host "Instalando $rol..." -ForegroundColor Cyan
        Install-WindowsFeature $rol -IncludeManagementTools
        Write-Host "Instalacion completada." -ForegroundColor Green
    }
}

function Desinstalar-Rol ($rol) {
    if (-not (Rol-Instalado $rol)) {
        Write-Host "Error: $rol no esta instalado." -ForegroundColor Red
    } else {
        Uninstall-WindowsFeature $rol -IncludeManagementTools
        Write-Host "SERVICIO DESINSTALADO CORRECTAMENTE" -ForegroundColor Green
    }
}
