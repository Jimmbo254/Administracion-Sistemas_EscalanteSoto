# http_functions.ps1 — Funciones HTTP / Servidores Web (Windows Server)

# ============================================================
# PUERTOS BLOQUEADOS
# ============================================================

$puertos_bloqueados = @(1,7,9,11,13,15,17,19,20,21,22,23,25,37,42,43,53,69,
    77,79,110,111,113,115,117,118,119,123,135,137,139,143,161,177,179,
    389,427,445,465,512,513,514,515,526,530,531,532,540,548,554,556,
    563,587,601,636,989,990,993,995,1723,2049,2222,3306,3389,5432)

$desc_puertos = @{
    20="FTP"; 21="FTP"; 22="SSH"; 25="SMTP"; 53="DNS";
    110="POP3"; 143="IMAP"; 445="SMB/Samba"; 2222="SSH-Alt";
    3306="MySQL"; 5432="PostgreSQL"; 3389="RDP"
}

# ============================================================
# UTILITARIAS
# ============================================================

function Pedir-Puerto {
    while ($true) {
        $puerto = Read-Host "  Puerto a utilizar (ej. 80, 8080, 8888)"
        if ($puerto -notmatch '^\d+$' -or [int]$puerto -le 0 -or [int]$puerto -gt 65535) {
            Write-Host "  [Error] Puerto invalido. Rango permitido: 1-65535." -ForegroundColor Red
            continue
        }
        $p = [int]$puerto
        if ($puertos_bloqueados -contains $p) {
            $desc = if ($desc_puertos.ContainsKey($p)) { $desc_puertos[$p] } else { "Reservado del sistema" }
            Write-Host "  [Error] Puerto $p en uso por: $desc." -ForegroundColor Red
            continue
        }
        $ocupado = netstat -ano | Select-String ":$p "
        if ($ocupado) {
            Write-Host "  [Error] Puerto $p ocupado por otro proceso." -ForegroundColor Red
            continue
        }
        return $p
    }
}

function Instalar-Chocolatey {
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Host "  Instalando Chocolatey..." -ForegroundColor Gray
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine")
        Write-Host "  [OK] Chocolatey instalado." -ForegroundColor Green
    }
}

function Obtener-Versiones {
    param($paquete)

    Instalar-Chocolatey

    Write-Host "  Consultando versiones disponibles para $paquete..." -ForegroundColor Gray

    # Consultar versiones dinamicamente via choco
    $raw = & choco list $paquete --all-versions --limit-output 2>/dev/null
    $versiones = @()
    foreach ($line in $raw) {
        $partes = $line -split '\|'
        if ($partes.Count -ge 2 -and $partes[0].Trim() -eq $paquete) {
            $versiones += $partes[1].Trim()
        }
    }

    # Ordenar y tomar las mas relevantes
    $versiones = $versiones | Sort-Object { [Version]($_ -replace '[^0-9.]','') } -ErrorAction SilentlyContinue | Select-Object -Last 5

    if ($versiones.Count -eq 0) {
        Write-Host "  [Error] No se encontraron versiones para $paquete." -ForegroundColor Red
        return $null
    }

    Write-Host ""
    Write-Host "  Versiones disponibles para ${paquete}:" -ForegroundColor Cyan    $i = 1
    $total = $versiones.Count
    foreach ($v in $versiones) {
        $etiqueta = ""
        if ($i -eq 1)      { $etiqueta = "[LTS - Estable]" }
        elseif ($i -eq $total) { $etiqueta = "[Latest - Desarrollo]" }
        else               { $etiqueta = "[Disponible]" }
        Write-Host ("    {0}) {1}  {2}" -f $i, $v, $etiqueta)
        $i++
    }
    Write-Host ""

    while ($true) {
        $sel = Read-Host "  Numero de version (1-$total)"
        if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $total) {
            return $versiones[[int]$sel - 1]
        }
        Write-Host "  [Error] Seleccion fuera de rango." -ForegroundColor Red
    }
}

function Generar-Index {
    param($ruta, $servicio, $version, $puerto)
    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } | Select-Object -First 1).IPAddress
    $html = @"
<!DOCTYPE html>
<html lang="es">
<head><meta charset="UTF-8"><title>$servicio</title></head>
<body>
  <h2>Servidor: $servicio</h2>
  <p>Version: $version</p>
  <p>IP: $ip</p>
  <p>Puerto: $puerto</p>
</body>
</html>
"@
    Set-Content -Path "$ruta\index.html" -Value $html -Encoding UTF8
}

function Abrir-Firewall {
    param($puerto, $nombre)
    Write-Host "  Abriendo puerto $puerto en firewall..." -ForegroundColor Gray
    $regla = "WebSrv_$nombre`_$puerto"
    Remove-NetFirewallRule -DisplayName $regla -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $regla `
        -Direction Inbound -Protocol TCP -LocalPort $puerto `
        -Action Allow -Profile Any | Out-Null
    Write-Host "  [OK] Puerto $puerto habilitado en firewall." -ForegroundColor Green
}

function Estado-Servicio {
    param($servicio, $puerto)
    Write-Host ""
    Write-Host "  ----[ $servicio : puerto $puerto ]----" -ForegroundColor Cyan
    $svc = Get-Service -Name $servicio -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Write-Host "  [OK] $servicio esta ACTIVO" -ForegroundColor Green
    } else {
        Write-Host "  [!!] $servicio esta INACTIVO" -ForegroundColor Red
    }
    $escuchando = netstat -ano | Select-String ":$puerto "
    if ($escuchando) {
        Write-Host "  [OK] Puerto $puerto escuchando" -ForegroundColor Green
    } else {
        Write-Host "  [??] Puerto $puerto no detectado aun" -ForegroundColor Yellow
    }
    Write-Host "  Encabezados HTTP:" -ForegroundColor Cyan
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:$puerto" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        Write-Host "       HTTP $($resp.StatusCode) $($resp.StatusDescription)" -ForegroundColor Green
        $resp.Headers.GetEnumerator() | Where-Object { $_.Key -match "Server|X-Frame|X-Content|X-XSS" } | ForEach-Object {
            Write-Host "       $($_.Key): $($_.Value)" -ForegroundColor Gray
        }
    } catch {
        Write-Host "       (Servicio iniciando o sin respuesta aun)" -ForegroundColor Yellow
    }
    Write-Host "  ------------------------------------------" -ForegroundColor Cyan
}

# ============================================================
# INSTALACION DE SERVIDORES
# ============================================================

function Setup-IIS {
    param($puerto)
    Write-Host ""
    Write-Host "  Configurando IIS en puerto $puerto..." -ForegroundColor Cyan
    $feature = Get-WindowsFeature -Name Web-Server
    if (-not $feature.Installed) {
        Write-Host "  Instalando rol Web-Server (IIS)..." -ForegroundColor Gray
        Install-WindowsFeature -Name Web-Server, Web-Common-Http, Web-Http-Errors, `
            Web-Static-Content, Web-Http-Logging, Web-Security -IncludeManagementTools | Out-Null
    }
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    $siteName = "IIS_$puerto"
    $webRoot  = "C:\inetpub\wwwroot_$puerto"
    New-Item -ItemType Directory -Path $webRoot -Force | Out-Null
    Remove-WebSite -Name $siteName -ErrorAction SilentlyContinue
    New-WebSite -Name $siteName -Port $puerto -PhysicalPath $webRoot -Force | Out-Null
    $version = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" -ErrorAction SilentlyContinue).VersionString
    if (-not $version) { $version = "IIS (Windows)" }
    Generar-Index -ruta $webRoot -servicio "IIS" -version $version -puerto $puerto
    $webconfig = @"
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <httpProtocol>
      <customHeaders>
        <add name="X-Frame-Options" value="SAMEORIGIN" />
        <add name="X-Content-Type-Options" value="nosniff" />
        <add name="X-XSS-Protection" value="1; mode=block" />
        <add name="Referrer-Policy" value="no-referrer-when-downgrade" />
        <remove name="X-Powered-By" />
      </customHeaders>
    </httpProtocol>
    <security>
      <requestFiltering>
        <verbs allowUnlisted="false">
          <add verb="GET" allowed="true" />
          <add verb="POST" allowed="true" />
          <add verb="HEAD" allowed="true" />
        </verbs>
      </requestFiltering>
    </security>
  </system.webServer>
</configuration>
"@
    Set-Content -Path "$webRoot\web.config" -Value $webconfig -Encoding UTF8
    Abrir-Firewall -puerto $puerto -nombre "IIS"
    Start-WebSite -Name $siteName -ErrorAction SilentlyContinue
    Start-Service -Name W3SVC -ErrorAction SilentlyContinue
    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } | Select-Object -First 1).IPAddress
    Write-Host ""
    Write-Host "  [OK] IIS listo en puerto $puerto." -ForegroundColor Green
    Write-Host "       Directorio : $webRoot" -ForegroundColor Gray
    Write-Host "       Accede en  : http://$ip`:$puerto" -ForegroundColor Green
    Estado-Servicio -servicio "W3SVC" -puerto $puerto
}

function Setup-Apache {
    param($version, $puerto)
    Write-Host ""
    Write-Host "  Configurando Apache $version en puerto $puerto..." -ForegroundColor Cyan
    Instalar-Chocolatey
    Write-Host "  Instalando Apache con Chocolatey..." -ForegroundColor Gray
    & choco install apache-httpd --version=$version -y --no-progress 2>&1 | Out-Null
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine")

    $apacheDir = "C:\Apache24"
    $apacheExe = "$apacheDir\bin\httpd.exe"
    if (-not (Test-Path $apacheExe)) {
        Write-Host "  [Error] Apache no se instalo correctamente." -ForegroundColor Red; return
    }

    $confFile = "$apacheDir\conf\httpd.conf"
    (Get-Content $confFile) -replace "^Listen \d+", "Listen $puerto" | Set-Content $confFile
    (Get-Content $confFile) -replace "^ServerName .*", "ServerName localhost:$puerto" | Set-Content $confFile

    $webRoot = "$apacheDir\htdocs_$puerto"
    New-Item -ItemType Directory -Path $webRoot -Force | Out-Null
    (Get-Content $confFile) -replace 'DocumentRoot ".*"', "DocumentRoot `"$($webRoot -replace '\\','/')`"" | Set-Content $confFile
    (Get-Content $confFile) -replace '<Directory ".*htdocs.*">', "<Directory `"$($webRoot -replace '\\','/')`">" | Set-Content $confFile

    $secConf = "$apacheDir\conf\extra\security.conf"
    $secContent = @"
ServerTokens Prod
ServerSignature Off
Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-Content-Type-Options "nosniff"
Header always set X-XSS-Protection "1; mode=block"
Header always set Referrer-Policy "no-referrer-when-downgrade"
Header always unset X-Powered-By
<Directory "/">
    <LimitExcept GET POST HEAD>
        Require all denied
    </LimitExcept>
</Directory>
"@
    Set-Content -Path $secConf -Value $secContent -Encoding UTF8
    if (-not (Select-String -Path $confFile -Pattern "security.conf" -Quiet)) {
        Add-Content -Path $confFile -Value "`nInclude conf/extra/security.conf"
    }

    Generar-Index -ruta $webRoot -servicio "Apache (httpd)" -version $version -puerto $puerto
    & "$apacheExe" -k install -n "Apache$puerto" 2>&1 | Out-Null
    Start-Service -Name "Apache$puerto" -ErrorAction SilentlyContinue
    Abrir-Firewall -puerto $puerto -nombre "Apache"

    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } | Select-Object -First 1).IPAddress
    Write-Host ""
    Write-Host "  [OK] Apache listo en puerto $puerto." -ForegroundColor Green
    Write-Host "       Directorio : $webRoot" -ForegroundColor Gray
    Write-Host "       Accede en  : http://$ip`:$puerto" -ForegroundColor Green
    Estado-Servicio -servicio "Apache$puerto" -puerto $puerto
}

function Setup-Nginx {
    param($version, $puerto)
    Write-Host ""
    Write-Host "  Configurando Nginx $version en puerto $puerto..." -ForegroundColor Cyan
    Instalar-Chocolatey
    Write-Host "  Instalando Nginx con Chocolatey..." -ForegroundColor Gray
    & choco install nginx --version=$version -y --no-progress 2>&1 | Out-Null
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine")

    $nginxDir = "C:\tools\nginx"
    if (-not (Test-Path "$nginxDir\nginx.exe")) {
        $nginxDir = "C:\nginx"
    }

    $webRoot = "$nginxDir\html_$puerto"
    New-Item -ItemType Directory -Path $webRoot -Force | Out-Null

    $confContent = @"
worker_processes  1;
events { worker_connections  1024; }
http {
    include       mime.types;
    default_type  application/octet-stream;
    server_tokens off;
    sendfile        on;
    keepalive_timeout  65;
    server {
        listen       $puerto;
        server_name  localhost;
        root         $($webRoot -replace '\\', '/');
        index        index.html;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Referrer-Policy "no-referrer-when-downgrade" always;
        location / {
            try_files `$uri `$uri/ =404;
        }
    }
}
"@
    Set-Content -Path "$nginxDir\conf\nginx.conf" -Value $confContent -Encoding UTF8
    Generar-Index -ruta $webRoot -servicio "Nginx" -version $version -puerto $puerto
    Abrir-Firewall -puerto $puerto -nombre "Nginx"

    Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Process -FilePath "$nginxDir\nginx.exe" -WorkingDirectory $nginxDir -WindowStyle Hidden

    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } | Select-Object -First 1).IPAddress
    Write-Host ""
    Write-Host "  [OK] Nginx listo en puerto $puerto." -ForegroundColor Green
    Write-Host "       Directorio : $webRoot" -ForegroundColor Gray
    Write-Host "       Accede en  : http://$ip`:$puerto" -ForegroundColor Green
    Start-Sleep -Seconds 3
    Estado-Servicio -servicio "nginx" -puerto $puerto
}

function Setup-Tomcat {
    param($version, $puerto)
    Write-Host ""
    Write-Host "  Configurando Tomcat $version en puerto $puerto..." -ForegroundColor Cyan
    Instalar-Chocolatey

    # Verificar Java
    if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
        Write-Host "  Instalando Java con Chocolatey..." -ForegroundColor Yellow
        & choco install openjdk17 -y --no-progress 2>&1 | Out-Null
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine")
    }

    Write-Host "  Instalando Tomcat con Chocolatey..." -ForegroundColor Gray
    & choco install tomcat --version=$version -y --no-progress 2>&1 | Out-Null
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine")

    $tomcatDir = "C:\Program Files\Apache Software Foundation\Tomcat*" | Resolve-Path -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $tomcatDir) { $tomcatDir = "C:\Tomcat" }

    $serverXml = "$tomcatDir\conf\server.xml"
    if (Test-Path $serverXml) {
        (Get-Content $serverXml) -replace 'port="\d+"', "port=`"$puerto`"" | Set-Content $serverXml
    }

    $webRoot = "$tomcatDir\webapps\ROOT"
    New-Item -ItemType Directory -Path $webRoot -Force | Out-Null
    Generar-Index -ruta $webRoot -servicio "Tomcat" -version $version -puerto $puerto

    Abrir-Firewall -puerto $puerto -nombre "Tomcat"
    $svc = Get-Service | Where-Object { $_.Name -like "Tomcat*" } | Select-Object -First 1
    if ($svc) { Restart-Service $svc.Name -ErrorAction SilentlyContinue }

    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } | Select-Object -First 1).IPAddress
    Write-Host ""
    Write-Host "  [OK] Tomcat listo en puerto $puerto." -ForegroundColor Green
    Write-Host "       Directorio : $webRoot" -ForegroundColor Gray
    Write-Host "       Accede en  : http://$ip`:$puerto" -ForegroundColor Green
    Start-Sleep -Seconds 5
    if ($svc) { Estado-Servicio -servicio $svc.Name -puerto $puerto }
}

# ============================================================
# DESINSTALAR / REINICIAR / LIMPIAR
# ============================================================

function Quitar-Servidor {
    Write-Host ""
    Write-Host "  === Desinstalar servidor ===" -ForegroundColor Cyan
    Write-Host "  1) IIS   2) Apache   3) Nginx   4) Tomcat"
    Write-Host ""
    $op = Read-Host "  Servidor a desinstalar (1-4)"
    switch ($op) {
        "1" {
            Stop-Service W3SVC -ErrorAction SilentlyContinue
            Uninstall-WindowsFeature -Name Web-Server -IncludeManagementTools | Out-Null
            Remove-Item "C:\inetpub\wwwroot_*" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  [OK] IIS desinstalado." -ForegroundColor Green
        }
        "2" {
            Get-Service | Where-Object { $_.Name -like "Apache*" } | ForEach-Object {
                Stop-Service $_.Name -ErrorAction SilentlyContinue
                & "C:\Apache24\bin\httpd.exe" -k uninstall -n $_.Name 2>&1 | Out-Null
            }
            Remove-Item "C:\Apache24" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  [OK] Apache desinstalado." -ForegroundColor Green
        }
        "3" {
            Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force
            Remove-Item "C:\tools\nginx" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item "C:\nginx" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  [OK] Nginx desinstalado." -ForegroundColor Green
        }
        "4" {
            Get-Service | Where-Object { $_.Name -like "Tomcat*" } | ForEach-Object {
                Stop-Service $_.Name -ErrorAction SilentlyContinue
            }
            & choco uninstall tomcat -y --no-progress 2>&1 | Out-Null
            Write-Host "  [OK] Tomcat desinstalado." -ForegroundColor Green
        }
        default { Write-Host "  [Error] Opcion no valida." -ForegroundColor Red }
    }
}

function Reiniciar-Servidor {
    Write-Host ""
    Write-Host "  === Levantar / Reiniciar servicio ===" -ForegroundColor Cyan
    $activos = @()
    if (Get-Service W3SVC -ErrorAction SilentlyContinue)         { $activos += "1) IIS (W3SVC)" }
    if (Test-Path "C:\Apache24\bin\httpd.exe")                   { $activos += "2) Apache (httpd)" }
    if ((Test-Path "C:\tools\nginx\nginx.exe") -or (Test-Path "C:\nginx\nginx.exe")) { $activos += "3) Nginx" }
    if (Get-Service | Where-Object { $_.Name -like "Tomcat*" })  { $activos += "4) Tomcat" }
    if ($activos.Count -eq 0) {
        Write-Host "  No hay servidores instalados." -ForegroundColor Yellow; return
    }
    $activos | ForEach-Object { Write-Host "    $_" }
    Write-Host ""
    $op     = Read-Host "  Selecciona (1-4)"
    $puerto = Read-Host "  Puerto para el servicio"
    if ($puerto -notmatch '^\d+$') { Write-Host "  [Error] Puerto no valido." -ForegroundColor Red; return }
    $p = [int]$puerto
    switch ($op) {
        "1" {
            Abrir-Firewall -puerto $p -nombre "IIS"
            Restart-Service W3SVC
            Write-Host "  [OK] IIS reiniciado en puerto $p." -ForegroundColor Green
            Estado-Servicio -servicio "W3SVC" -puerto $p
        }
        "2" {
            $confFile = "C:\Apache24\conf\httpd.conf"
            (Get-Content $confFile) -replace "^Listen \d+", "Listen $p" | Set-Content $confFile
            Abrir-Firewall -puerto $p -nombre "Apache"
            Get-Service | Where-Object { $_.Name -like "Apache*" } | Restart-Service -ErrorAction SilentlyContinue
            Write-Host "  [OK] Apache reiniciado en puerto $p." -ForegroundColor Green
            $svcName = (Get-Service | Where-Object { $_.Name -like "Apache*" } | Select-Object -First 1).Name
            Estado-Servicio -servicio $svcName -puerto $p
        }
        "3" {
            $nginxDir = if (Test-Path "C:\tools\nginx\nginx.exe") { "C:\tools\nginx" } else { "C:\nginx" }
            $conf = (Get-Content "$nginxDir\conf\nginx.conf") -replace "listen\s+\d+", "listen $p"
            Set-Content "$nginxDir\conf\nginx.conf" $conf
            Abrir-Firewall -puerto $p -nombre "Nginx"
            Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Process -FilePath "$nginxDir\nginx.exe" -WorkingDirectory $nginxDir -WindowStyle Hidden
            Write-Host "  [OK] Nginx reiniciado en puerto $p." -ForegroundColor Green
            Estado-Servicio -servicio "nginx" -puerto $p
        }
        "4" {
            $svc = Get-Service | Where-Object { $_.Name -like "Tomcat*" } | Select-Object -First 1
            if ($svc) {
                Restart-Service $svc.Name -ErrorAction SilentlyContinue
                Write-Host "  [OK] Tomcat reiniciado en puerto $p." -ForegroundColor Green
                Estado-Servicio -servicio $svc.Name -puerto $p
            }
        }
        default { Write-Host "  [Error] Opcion no valida." -ForegroundColor Red }
    }
}

function Limpiar-Entorno {
    Write-Host ""
    Write-Host "  Limpiando entorno web completo..." -ForegroundColor Yellow
    Stop-Service W3SVC -ErrorAction SilentlyContinue
    Uninstall-WindowsFeature -Name Web-Server -IncludeManagementTools -ErrorAction SilentlyContinue | Out-Null
    Remove-Item "C:\inetpub\wwwroot_*" -Recurse -Force -ErrorAction SilentlyContinue
    Get-Service | Where-Object { $_.Name -like "Apache*" } | ForEach-Object {
        Stop-Service $_.Name -ErrorAction SilentlyContinue
        & "C:\Apache24\bin\httpd.exe" -k uninstall -n $_.Name 2>&1 | Out-Null
    }
    Remove-Item "C:\Apache24" -Recurse -Force -ErrorAction SilentlyContinue
    Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-Item "C:\tools\nginx" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "C:\nginx" -Recurse -Force -ErrorAction SilentlyContinue
    Get-Service | Where-Object { $_.Name -like "Tomcat*" } | ForEach-Object {
        Stop-Service $_.Name -ErrorAction SilentlyContinue
    }
    & choco uninstall tomcat -y --no-progress 2>&1 | Out-Null
    Write-Host "  [OK] Entorno limpio y listo." -ForegroundColor Green
}

function Flujo-Instalar {
    param($tipo, $nombre)
    Write-Host ""
    Write-Host "  === Instalacion: $nombre ===" -ForegroundColor Cyan

    # IIS no necesita seleccion de version
    if ($tipo -eq "iis") {
        $puerto = Pedir-Puerto
        $conf = Read-Host "  ¿Iniciar instalacion de $nombre en puerto $puerto? (s/N)"
        if ($conf -notmatch '^[sS]$') { Write-Host "  Instalacion cancelada."; return }
        Setup-IIS -puerto $puerto
        return
    }

    # Para Apache, Nginx y Tomcat consultar versiones dinamicamente
    $pkgMap = @{ "apache" = "apache-httpd"; "nginx" = "nginx"; "tomcat" = "tomcat" }
    $pkg    = $pkgMap[$tipo]
    $version = Obtener-Versiones -paquete $pkg
    if (-not $version) { return }

    $puerto = Pedir-Puerto
    Write-Host "  Version  : $version"
    Write-Host "  Puerto   : $puerto"
    Write-Host ""
    $conf = Read-Host "  ¿Iniciar instalacion de $nombre en puerto $puerto? (s/N)"
    if ($conf -notmatch '^[sS]$') { Write-Host "  Instalacion cancelada."; return }

    switch ($tipo) {
        "apache" { Setup-Apache -version $version -puerto $puerto }
        "nginx"  { Setup-Nginx  -version $version -puerto $puerto }
        "tomcat" { Setup-Tomcat -version $version -puerto $puerto }
    }
}

function Flujo-Verificar {
    Write-Host ""
    Write-Host "  === Verificar servicio ===" -ForegroundColor Cyan
    Write-Host "  1) IIS   2) Apache   3) Nginx   4) Tomcat"
    Write-Host ""
    $op     = Read-Host "  Selecciona (1-4)"
    $puerto = Read-Host "  Puerto del servicio"
    if ($puerto -notmatch '^\d+$') { Write-Host "  [Error] Puerto no valido." -ForegroundColor Red; return }
    $servicio = switch ($op) {
        "1" { "W3SVC" }
        "2" { (Get-Service | Where-Object { $_.Name -like "Apache*" } | Select-Object -First 1).Name }
        "3" { "nginx" }
        "4" { (Get-Service | Where-Object { $_.Name -like "Tomcat*" } | Select-Object -First 1).Name }
        default { Write-Host "  [Error] Opcion no valida." -ForegroundColor Red; return }
    }
    Estado-Servicio -servicio $servicio -puerto ([int]$puerto)
}
