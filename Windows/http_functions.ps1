# http_functions.ps1 — Funciones HTTP Windows Server

$VM_IP = "192.168.56.102"

$PUERTOS_RESERVADOS = @(20,21,22,23,25,53,110,143,445,3306,3389,5432)

function Solicitar-Puerto {
    param([string]$Servicio)
    while ($true) {
        $input_p = Read-Host "  Puerto para $Servicio (ej. 80, 8080, 8888)"
        if ($input_p -notmatch '^\d+$') {
            Write-Host "  [Error] Solo numeros." -ForegroundColor Red; continue
        }
        $p = [int]$input_p
        if ($PUERTOS_RESERVADOS -contains $p) {
            Write-Host "  [Error] Puerto $p reservado por el sistema." -ForegroundColor Red; continue
        }
        $ocupado = netstat -ano | Select-String ":$p "
        if ($ocupado) {
            Write-Host "  [Error] Puerto $p ya esta en uso." -ForegroundColor Red; continue
        }
        return $p
    }
}

function Crear-Index {
    param([string]$Ruta, [string]$Servicio, [string]$Version, [int]$Puerto)
    if (!(Test-Path $Ruta)) { New-Item -Path $Ruta -ItemType Directory -Force | Out-Null }
    $html = @"
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <title>$Servicio</title>
</head>
<body>
  <h2>Servidor: $Servicio</h2>
  <p>Version: $Version</p>
  <p>Puerto: $Puerto</p>
  <p>IP: $VM_IP</p>
</body>
</html>
"@
    [IO.File]::WriteAllText("$Ruta\index.html", $html)
}

function Abrir-Firewall {
    param([int]$Puerto, [string]$Nombre)
    $regla = "WebHTTP_${Nombre}_${Puerto}"
    Remove-NetFirewallRule -DisplayName $regla -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $regla -Direction Inbound -Protocol TCP `
        -LocalPort $Puerto -Action Allow -Profile Any | Out-Null
    Write-Host "  [OK] Puerto $Puerto abierto en firewall." -ForegroundColor Green
}

# ============================================================
# IIS
# ============================================================

function Instalar-IIS {
    Write-Host ""
    Write-Host "  === Instalando IIS ===" -ForegroundColor Cyan
    $puerto = Solicitar-Puerto -Servicio "IIS"

    $feature = Get-WindowsFeature -Name Web-Server
    if (-not $feature.Installed) {
        Write-Host "  Instalando rol IIS..." -ForegroundColor Yellow
        Install-WindowsFeature -Name Web-Server, Web-Common-Http, Web-Static-Content, `
            Web-Http-Errors, Web-Http-Logging, Web-Security -IncludeManagementTools | Out-Null
        Write-Host "  [OK] IIS instalado." -ForegroundColor Green
    } else {
        Write-Host "  [OK] IIS ya estaba instalado." -ForegroundColor Green
    }

    Import-Module WebAdministration -ErrorAction SilentlyContinue

    $siteName = "MiSitio_$puerto"
    $webRoot  = "C:\inetpub\wwwroot_$puerto"
    New-Item -ItemType Directory -Path $webRoot -Force | Out-Null

    $version = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" -ErrorAction SilentlyContinue).VersionString
    if (-not $version) { $version = "IIS Windows" }

    Crear-Index -Ruta $webRoot -Servicio "IIS" -Version $version -Puerto $puerto

    Remove-WebSite -Name $siteName -ErrorAction SilentlyContinue
    New-WebSite -Name $siteName -Port $puerto -PhysicalPath $webRoot -Force | Out-Null
    Start-WebSite -Name $siteName -ErrorAction SilentlyContinue

    Set-Service -Name W3SVC -StartupType Automatic
    Start-Service -Name W3SVC -ErrorAction SilentlyContinue

    Abrir-Firewall -Puerto $puerto -Nombre "IIS"

    Write-Host "  [OK] IIS activo en puerto $puerto." -ForegroundColor Green
    Write-Host "  Abre: http://${VM_IP}:${puerto}" -ForegroundColor Yellow
}

function Desinstalar-IIS {
    Write-Host ""
    Write-Host "  === Desinstalando IIS ===" -ForegroundColor Cyan
    Stop-Service W3SVC -Force -ErrorAction SilentlyContinue
    Uninstall-WindowsFeature -Name Web-Server -IncludeManagementTools | Out-Null
    Remove-Item "C:\inetpub\wwwroot_*" -Recurse -Force -ErrorAction SilentlyContinue
    Get-NetFirewallRule -DisplayName "WebHTTP_IIS_*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Write-Host "  [OK] IIS desinstalado." -ForegroundColor Green
}

# ============================================================
# APACHE
# ============================================================

function Instalar-Apache {
    Write-Host ""
    Write-Host "  === Instalando Apache ===" -ForegroundColor Cyan
    $puerto = Solicitar-Puerto -Servicio "Apache"

    # Instalar Chocolatey si no existe
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Host "  Instalando Chocolatey..." -ForegroundColor Yellow
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine")
    }

    Write-Host "  Instalando Apache con Chocolatey..." -ForegroundColor Yellow
    choco install apache-httpd -y --force | Out-Null
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine")
    Start-Sleep -Seconds 3

    # Buscar httpd.conf
    $conf = Get-ChildItem -Path "C:\tools","C:\Apache24" -Filter "httpd.conf" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $conf) {
        Write-Host "  [Error] No se encontro httpd.conf." -ForegroundColor Red; return
    }

    $apacheRoot   = $conf.Directory.Parent.FullName
    $apacheRootFmt = $apacheRoot -replace "\\", "/"
    $htdocs       = "$apacheRoot\htdocs"

    $texto = Get-Content $conf.FullName
    $texto = $texto -replace 'Define SRVROOT .*',      "Define SRVROOT `"$apacheRootFmt`""
    $texto = $texto -replace '(?i)c:/Apache24',         $apacheRootFmt
    $texto = $texto -replace '(?m)^Listen\s+\d+',      "Listen $puerto"
    $texto = $texto -replace '(?m)^#?\s*ServerName.*', "ServerName localhost:$puerto"
    $texto | Set-Content $conf.FullName

    Crear-Index -Ruta $htdocs -Servicio "Apache" -Version "Latest" -Puerto $puerto

    $httpd = Get-ChildItem -Path $apacheRoot -Filter "httpd.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($httpd) {
        & $httpd.FullName -k uninstall 2>$null
        Stop-Process -Name "httpd" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        & $httpd.FullName -k install 2>$null
        Start-Sleep -Seconds 2
        net start Apache2.4
    } else {
        Write-Host "  [Error] No se encontro httpd.exe." -ForegroundColor Red; return
    }

    Abrir-Firewall -Puerto $puerto -Nombre "Apache"
    Write-Host "  [OK] Apache activo en puerto $puerto." -ForegroundColor Green
    Write-Host "  Abre: http://${VM_IP}:${puerto}" -ForegroundColor Yellow
}

function Desinstalar-Apache {
    Write-Host ""
    Write-Host "  === Desinstalando Apache ===" -ForegroundColor Cyan
    net stop Apache2.4 2>$null
    $httpd = Get-ChildItem -Path "C:\tools","C:\Apache24" -Filter "httpd.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($httpd) { & $httpd.FullName -k uninstall 2>$null }
    Stop-Process -Name "httpd" -Force -ErrorAction SilentlyContinue
    choco uninstall apache-httpd -y | Out-Null
    Get-ChildItem -Path "C:\tools" -Filter "*apache*" -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-NetFirewallRule -DisplayName "WebHTTP_Apache_*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Write-Host "  [OK] Apache desinstalado." -ForegroundColor Green
}

# ============================================================
# NGINX
# ============================================================

function Instalar-Nginx {
    Write-Host ""
    Write-Host "  === Instalando Nginx ===" -ForegroundColor Cyan
    $puerto = Solicitar-Puerto -Servicio "Nginx"

    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Host "  Instalando Chocolatey..." -ForegroundColor Yellow
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine")
    }

    Write-Host "  Instalando Nginx con Chocolatey..." -ForegroundColor Yellow
    choco install nginx -y --force | Out-Null
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine")
    Start-Sleep -Seconds 3

    $conf = Get-ChildItem -Path "C:\tools","C:\nginx" -Filter "nginx.conf" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $conf) {
        Write-Host "  [Error] No se encontro nginx.conf." -ForegroundColor Red; return
    }

    $nginxRoot = $conf.Directory.Parent.FullName
    $htmlDir   = "$nginxRoot\html"

    Stop-Process -Name "nginx" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    $texto = Get-Content $conf.FullName
    $texto = $texto -replace '(?m)^\s*listen\s+\d+\s*;', "        listen       $puerto;"
    $texto | Set-Content $conf.FullName

    Crear-Index -Ruta $htmlDir -Servicio "Nginx" -Version "Latest" -Puerto $puerto

    $exe = Get-ChildItem -Path $nginxRoot -Filter "nginx.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) {
        Start-Process $exe.FullName -WorkingDirectory $exe.Directory.FullName -WindowStyle Hidden
    } else {
        Write-Host "  [Error] No se encontro nginx.exe." -ForegroundColor Red; return
    }

    Abrir-Firewall -Puerto $puerto -Nombre "Nginx"
    Write-Host "  [OK] Nginx activo en puerto $puerto." -ForegroundColor Green
    Write-Host "  Abre: http://${VM_IP}:${puerto}" -ForegroundColor Yellow
}

function Desinstalar-Nginx {
    Write-Host ""
    Write-Host "  === Desinstalando Nginx ===" -ForegroundColor Cyan
    Stop-Process -Name "nginx" -Force -ErrorAction SilentlyContinue
    choco uninstall nginx -y | Out-Null
    Get-ChildItem -Path "C:\tools" -Filter "*nginx*" -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-NetFirewallRule -DisplayName "WebHTTP_Nginx_*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Write-Host "  [OK] Nginx desinstalado." -ForegroundColor Green
}
