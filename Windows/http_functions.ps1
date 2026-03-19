# http_functions.ps1 — Funciones HTTP Windows Server

$puertosReservados = @(1,7,9,11,13,15,17,19,20,21,22,23,25,37,42,43,53,69,
    77,79,110,111,113,115,117,118,119,123,135,137,139,143,161,177,179,
    389,427,445,465,512,513,514,515,526,530,531,532,540,548,554,556,
    563,587,601,636,989,990,993,995,1723,2049,2222,3306,3389,5432)

$serviciosPuertos = @{
    20="FTP"; 21="FTP"; 22="SSH"; 25="SMTP"; 53="DNS";
    110="POP3"; 143="IMAP"; 445="SMB/Samba"; 2222="SSH alternativo";
    3306="MySQL/MariaDB"; 5432="PostgreSQL"; 3389="RDP"
}

function Solicitar-Puerto {
    while ($true) {
        $puerto = Read-Host "  Ingrese el puerto (ej. 80, 8080, 8888)"
        if ($puerto -notmatch '^\d+$' -or [int]$puerto -le 0 -or [int]$puerto -gt 65535) {
            Write-Host "  Error: Ingresa un numero de puerto valido (1-65535)." -ForegroundColor Red
            continue
        }
        $p = [int]$puerto
        if ($puertosReservados -contains $p) {
            $desc = if ($serviciosPuertos.ContainsKey($p)) { $serviciosPuertos[$p] } else { "Sistema Critico" }
            Write-Host "  Error: Puerto $p reservado para $desc. Elige otro." -ForegroundColor Red
            continue
        }
        $ocupado = netstat -ano | Select-String ":$p "
        if ($ocupado) {
            Write-Host "  Error: El puerto $p ya esta ocupado por otro servicio." -ForegroundColor Red
            continue
        }
        return $p
    }
}

function Crear-Index {
    param($ruta, $servicio, $version, $puerto)
    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } | Select-Object -First 1).IPAddress
    $html = @"
<!DOCTYPE html>
<html lang="es">
<head><meta charset="UTF-8"><title>$servicio</title></head>
<body>
  <h2>$servicio</h2>
  <p>Version: $version</p>
  <p>IP: $ip</p>
  <p>Puerto: $puerto</p>
</body>
</html>
"@
    Set-Content -Path "$ruta\index.html" -Value $html -Encoding UTF8
}

function Configurar-Firewall {
    param($puerto, $nombre)
    Write-Host "  Configurando firewall: abriendo puerto $puerto..." -ForegroundColor Gray
    $ruleName = "WebServer_$nombre`_$puerto"
    Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $ruleName `
        -Direction Inbound -Protocol TCP -LocalPort $puerto `
        -Action Allow -Profile Any | Out-Null
    Write-Host "  Firewall configurado. Puerto $puerto habilitado." -ForegroundColor Green
}

function Verificar-Servicio {
    param($servicio, $puerto)
    Write-Host ""
    Write-Host "  +------ Verificacion: $servicio en puerto $puerto ------+" -ForegroundColor Cyan
    $svc = Get-Service -Name $servicio -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Write-Host "  [OK] Servicio $servicio : ACTIVO" -ForegroundColor Green
    } else {
        Write-Host "  [!!] Servicio $servicio : INACTIVO" -ForegroundColor Red
    }
    $escuchando = netstat -ano | Select-String ":$puerto "
    if ($escuchando) {
        Write-Host "  [OK] Puerto $puerto     : ESCUCHANDO" -ForegroundColor Green
    } else {
        Write-Host "  [??] Puerto $puerto     : No detectado aun" -ForegroundColor Yellow
    }
    Write-Host "  [>>] Encabezados HTTP (Invoke-WebRequest http://localhost:$puerto):" -ForegroundColor Cyan
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:$puerto" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        Write-Host "       HTTP $($resp.StatusCode) $($resp.StatusDescription)" -ForegroundColor Green
        $resp.Headers.GetEnumerator() | Where-Object { $_.Key -match "Server|X-Frame|X-Content|X-XSS" } | ForEach-Object {
            Write-Host "       $($_.Key): $($_.Value)" -ForegroundColor Gray
        }
    } catch {
        Write-Host "       (Servicio aun iniciando o no responde)" -ForegroundColor Yellow
    }
    Write-Host "  +---------------------------------------------------+" -ForegroundColor Cyan
}

function Instalar-IIS {
    param($puerto)
    Write-Host ""
    Write-Host "  Instalando IIS en puerto $puerto..." -ForegroundColor Cyan
    $feature = Get-WindowsFeature -Name Web-Server
    if (-not $feature.Installed) {
        Write-Host "  Instalando rol Web-Server (IIS)..." -ForegroundColor Gray
        Install-WindowsFeature -Name Web-Server, Web-Common-Http, Web-Http-Errors, `
            Web-Static-Content, Web-Http-Logging, Web-Security -IncludeManagementTools | Out-Null
    }
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    $siteName = "IIS_$puerto"
    $webRoot = "C:\inetpub\wwwroot_$puerto"
    New-Item -ItemType Directory -Path $webRoot -Force | Out-Null
    Remove-WebSite -Name $siteName -ErrorAction SilentlyContinue
    New-WebSite -Name $siteName -Port $puerto -PhysicalPath $webRoot -Force | Out-Null
    $version = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" -ErrorAction SilentlyContinue).VersionString
    if (-not $version) { $version = "IIS (Windows)" }
    Crear-Index -ruta $webRoot -servicio "IIS" -version $version -puerto $puerto
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
    Configurar-Firewall -puerto $puerto -nombre "IIS"
    Start-WebSite -Name $siteName -ErrorAction SilentlyContinue
    Start-Service -Name W3SVC -ErrorAction SilentlyContinue
    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } | Select-Object -First 1).IPAddress
    Write-Host ""
    Write-Host "  [OK] IIS instalado y asegurado." -ForegroundColor Green
    Write-Host "       Ruta web : $webRoot" -ForegroundColor Gray
    Write-Host "       Accede en: http://$ip`:$puerto" -ForegroundColor Green
    Verificar-Servicio -servicio "W3SVC" -puerto $puerto
}

function Instalar-Apache {
    param($puerto)
    Write-Host ""
    Write-Host "  Instalando Apache (httpd) en puerto $puerto..." -ForegroundColor Cyan
    $apacheDir = "C:\Apache24"
    $apacheExe = "$apacheDir\bin\httpd.exe"
    if (-not (Test-Path $apacheExe)) {
        if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
            Write-Host "  Instalando Chocolatey..." -ForegroundColor Gray
            Set-ExecutionPolicy Bypass -Scope Process -Force
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
            Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
            $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine")
        }
        Write-Host "  Instalando Apache con Chocolatey..." -ForegroundColor Gray
        try {
            & choco install apache-httpd -y --no-progress 2>&1 | Out-Null
            $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine")
        } catch {
            Write-Host "  Error instalando Apache." -ForegroundColor Red
            return
        }
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
    $version = & "$apacheDir\bin\httpd.exe" -v 2>&1 | Select-String "Apache/" | ForEach-Object { $_ -replace ".*Apache/(\S+).*",'$1' }
    if (-not $version) { $version = "2.4.x" }
    Crear-Index -ruta $webRoot -servicio "Apache (httpd)" -version $version -puerto $puerto
    & "$apacheExe" -k install -n "Apache$puerto" 2>&1 | Out-Null
    Start-Service -Name "Apache$puerto" -ErrorAction SilentlyContinue
    Configurar-Firewall -puerto $puerto -nombre "Apache"
    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } | Select-Object -First 1).IPAddress
    Write-Host ""
    Write-Host "  [OK] Apache instalado y asegurado." -ForegroundColor Green
    Write-Host "       Ruta web : $webRoot" -ForegroundColor Gray
    Write-Host "       Accede en: http://$ip`:$puerto" -ForegroundColor Green
    Verificar-Servicio -servicio "Apache$puerto" -puerto $puerto
}

function Instalar-Nginx {
    param($puerto)
    Write-Host ""
    Write-Host "  Instalando Nginx en puerto $puerto..." -ForegroundColor Cyan
    $nginxDir = "C:\nginx"
    if (-not (Test-Path "$nginxDir\nginx.exe")) {
        Write-Host "  Descargando Nginx para Windows..." -ForegroundColor Gray
        $url = "https://nginx.org/download/nginx-1.26.2.zip"
        $zipPath = "$env:TEMP\nginx.zip"
        try {
            Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
            Write-Host "  Extrayendo Nginx..." -ForegroundColor Gray
            Expand-Archive -Path $zipPath -DestinationPath "C:\" -Force
            $extracted = Get-ChildItem "C:\" -Filter "nginx-*" -Directory | Select-Object -First 1
            if ($extracted) { Rename-Item $extracted.FullName $nginxDir -Force }
            Remove-Item $zipPath -Force
        } catch {
            Write-Host "  Error descargando Nginx." -ForegroundColor Red
            return
        }
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
    Crear-Index -ruta $webRoot -servicio "Nginx" -version "1.26.2" -puerto $puerto
    Configurar-Firewall -puerto $puerto -nombre "Nginx"
    $nssm = Get-Command nssm -ErrorAction SilentlyContinue
    if ($nssm) {
        & nssm install "Nginx" "$nginxDir\nginx.exe" 2>&1 | Out-Null
        Start-Service "Nginx" -ErrorAction SilentlyContinue
    } else {
        Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Process -FilePath "$nginxDir\nginx.exe" -WorkingDirectory $nginxDir -WindowStyle Hidden
    }
    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } | Select-Object -First 1).IPAddress
    Write-Host ""
    Write-Host "  [OK] Nginx instalado y corriendo." -ForegroundColor Green
    Write-Host "       Ruta web : $webRoot" -ForegroundColor Gray
    Write-Host "       Accede en: http://$ip`:$puerto" -ForegroundColor Green
    Start-Sleep -Seconds 3
    Verificar-Servicio -servicio "nginx" -puerto $puerto
}

function Instalar-Tomcat {
    param($puerto)
    Write-Host ""
    Write-Host "  Instalando Tomcat en puerto $puerto..." -ForegroundColor Cyan
    $java = Get-Command java -ErrorAction SilentlyContinue
    if (-not $java) {
        Write-Host "  Java no encontrado. Instalando OpenJDK 17..." -ForegroundColor Yellow
        $jdkUrl = "https://aka.ms/download-jdk/microsoft-jdk-17-windows-x64.msi"
        $jdkMsi = "$env:TEMP\jdk17.msi"
        try {
            Invoke-WebRequest -Uri $jdkUrl -OutFile $jdkMsi -UseBasicParsing
            Start-Process msiexec.exe -Wait -ArgumentList "/i $jdkMsi /quiet"
            Remove-Item $jdkMsi -Force
            $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine")
        } catch {
            Write-Host "  Error instalando Java." -ForegroundColor Red
            return
        }
    }
    $tomcatDir = "C:\Tomcat10"
    if (-not (Test-Path "$tomcatDir\bin\catalina.bat")) {
        Write-Host "  Descargando Tomcat 10..." -ForegroundColor Gray
        $url = "https://downloads.apache.org/tomcat/tomcat-10/v10.1.26/bin/apache-tomcat-10.1.26-windows-x64.zip"
        $zipPath = "$env:TEMP\tomcat.zip"
        try {
            Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
            Write-Host "  Extrayendo Tomcat..." -ForegroundColor Gray
            Expand-Archive -Path $zipPath -DestinationPath "$env:TEMP\tomcat_extract" -Force
            $extracted = Get-ChildItem "$env:TEMP\tomcat_extract" | Select-Object -First 1
            Move-Item $extracted.FullName $tomcatDir -Force
            Remove-Item $zipPath -Force
            Remove-Item "$env:TEMP\tomcat_extract" -Recurse -Force
        } catch {
            Write-Host "  Error descargando Tomcat." -ForegroundColor Red
            return
        }
    }
    $serverXml = "$tomcatDir\conf\server.xml"
    (Get-Content $serverXml) -replace 'port="\d+"', "port=`"$puerto`"" | Set-Content $serverXml
    $webRoot = "$tomcatDir\webapps\ROOT"
    New-Item -ItemType Directory -Path $webRoot -Force | Out-Null
    Crear-Index -ruta $webRoot -servicio "Tomcat" -version "10.1.x" -puerto $puerto
    $serviceScript = "$tomcatDir\bin\service.bat"
    if (Test-Path $serviceScript) {
        $env:CATALINA_HOME = $tomcatDir
        & cmd /c "`"$serviceScript`" install Tomcat$puerto" 2>&1 | Out-Null
    } else {
        Start-Process -FilePath "$tomcatDir\bin\startup.bat" -WindowStyle Hidden
    }
    Start-Service -Name "Tomcat$puerto" -ErrorAction SilentlyContinue
    Configurar-Firewall -puerto $puerto -nombre "Tomcat"
    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } | Select-Object -First 1).IPAddress
    Write-Host ""
    Write-Host "  [OK] Tomcat instalado." -ForegroundColor Green
    Write-Host "       Ruta web : $webRoot" -ForegroundColor Gray
    Write-Host "       Accede en: http://$ip`:$puerto" -ForegroundColor Green
    Start-Sleep -Seconds 5
    Verificar-Servicio -servicio "Tomcat$puerto" -puerto $puerto
}

function Desinstalar-Servidor {
    Write-Host ""
    Write-Host "  === Desinstalar servidor ===" -ForegroundColor Cyan
    Write-Host "  1) IIS   2) Apache (httpd)   3) Nginx   4) Tomcat"
    Write-Host ""
    $op = Read-Host "  Selecciona el servidor (1-4)"
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
            Remove-Item "C:\nginx" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  [OK] Nginx desinstalado." -ForegroundColor Green
        }
        "4" {
            Get-Service | Where-Object { $_.Name -like "Tomcat*" } | ForEach-Object {
                Stop-Service $_.Name -ErrorAction SilentlyContinue
                $env:CATALINA_HOME = "C:\Tomcat10"
                & cmd /c "`"C:\Tomcat10\bin\service.bat`" remove $($_.Name)" 2>&1 | Out-Null
            }
            Remove-Item "C:\Tomcat10" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  [OK] Tomcat desinstalado." -ForegroundColor Green
        }
        default { Write-Host "  Opcion invalida." -ForegroundColor Red }
    }
}

function Levantar-Servicio {
    Write-Host ""
    Write-Host "  === Levantar / Reiniciar servicio ===" -ForegroundColor Cyan
    $instalados = @()
    if (Get-Service W3SVC -ErrorAction SilentlyContinue) { $instalados += "1) IIS (W3SVC)" }
    if (Test-Path "C:\Apache24\bin\httpd.exe")            { $instalados += "2) Apache (httpd)" }
    if (Test-Path "C:\Tomcat10\bin\catalina.bat")         { $instalados += "3) Tomcat" }
    if ($instalados.Count -eq 0) {
        Write-Host "  No hay ningun servidor instalado." -ForegroundColor Yellow; return
    }
    $instalados | ForEach-Object { Write-Host "    $_" }
    Write-Host ""
    $op     = Read-Host "  Selecciona el servicio (1-3)"
    $puerto = Read-Host "  Ingresa el puerto en el que debe correr"
    if ($puerto -notmatch '^\d+$') { Write-Host "  Puerto invalido." -ForegroundColor Red; return }
    $p = [int]$puerto
    switch ($op) {
        "1" {
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            $siteName = "IIS_$p"
            $site = Get-WebSite -Name $siteName -ErrorAction SilentlyContinue
            if ($site) {
                Set-WebBinding -Name $siteName -BindingInformation "*:$($site.Bindings.Collection[0].bindingInformation.Split(':')[1]):" -PropertyName Port -Value $p
            }
            Configurar-Firewall -puerto $p -nombre "IIS"
            Restart-Service W3SVC
            Write-Host "  [OK] IIS reiniciado en puerto $p." -ForegroundColor Green
            $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } | Select-Object -First 1).IPAddress
            Write-Host "  Accede en: http://$ip`:$p" -ForegroundColor Green
            Verificar-Servicio -servicio "W3SVC" -puerto $p
        }
        "2" {
            $confFile = "C:\Apache24\conf\httpd.conf"
            (Get-Content $confFile) -replace "^Listen \d+", "Listen $p" | Set-Content $confFile
            Configurar-Firewall -puerto $p -nombre "Apache"
            Get-Service | Where-Object { $_.Name -like "Apache*" } | Restart-Service -ErrorAction SilentlyContinue
            Write-Host "  [OK] Apache reiniciado en puerto $p." -ForegroundColor Green
            $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } | Select-Object -First 1).IPAddress
            Write-Host "  Accede en: http://$ip`:$p" -ForegroundColor Green
            $svcName = (Get-Service | Where-Object { $_.Name -like "Apache*" } | Select-Object -First 1).Name
            Verificar-Servicio -servicio $svcName -puerto $p
        }
        "3" {
            $serverXml = "C:\Tomcat10\conf\server.xml"
            (Get-Content $serverXml) -replace 'port="\d+"', "port=`"$p`"" | Set-Content $serverXml
            Configurar-Firewall -puerto $p -nombre "Tomcat"
            Get-Service | Where-Object { $_.Name -like "Tomcat*" } | Restart-Service -ErrorAction SilentlyContinue
            Write-Host "  [OK] Tomcat reiniciado en puerto $p." -ForegroundColor Green
            $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } | Select-Object -First 1).IPAddress
            Write-Host "  Accede en: http://$ip`:$p" -ForegroundColor Green
            $svcName = (Get-Service | Where-Object { $_.Name -like "Tomcat*" } | Select-Object -First 1).Name
            Verificar-Servicio -servicio $svcName -puerto $p
        }
        default { Write-Host "  Opcion invalida." -ForegroundColor Red }
    }
}

function Flujo-Verificacion {
    Write-Host ""
    Write-Host "  === Verificacion de servicio ===" -ForegroundColor Cyan
    Write-Host "  1) IIS (W3SVC)   2) Apache   3) Tomcat"
    Write-Host ""
    $op     = Read-Host "  Selecciona el servicio (1-3)"
    $puerto = Read-Host "  Ingresa el puerto del servicio"
    if ($puerto -notmatch '^\d+$') { Write-Host "  Puerto invalido." -ForegroundColor Red; return }
    $servicio = switch ($op) {
        "1" { "W3SVC" }
        "2" { (Get-Service | Where-Object { $_.Name -like "Apache*" } | Select-Object -First 1).Name }
        "3" { (Get-Service | Where-Object { $_.Name -like "Tomcat*" } | Select-Object -First 1).Name }
        default { Write-Host "  Opcion invalida." -ForegroundColor Red; return }
    }
    Verificar-Servicio -servicio $servicio -puerto ([int]$puerto)
}

function Limpiar-Entorno {
    Write-Host ""
    Write-Host "  Limpiando entorno completo..." -ForegroundColor Yellow
    Stop-Service W3SVC -ErrorAction SilentlyContinue
    Uninstall-WindowsFeature -Name Web-Server -IncludeManagementTools -ErrorAction SilentlyContinue | Out-Null
    Remove-Item "C:\inetpub\wwwroot_*" -Recurse -Force -ErrorAction SilentlyContinue
    Get-Service | Where-Object { $_.Name -like "Apache*" } | ForEach-Object {
        Stop-Service $_.Name -ErrorAction SilentlyContinue
        & "C:\Apache24\bin\httpd.exe" -k uninstall -n $_.Name 2>&1 | Out-Null
    }
    Remove-Item "C:\Apache24" -Recurse -Force -ErrorAction SilentlyContinue
    Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-Item "C:\nginx" -Recurse -Force -ErrorAction SilentlyContinue
    Get-Service | Where-Object { $_.Name -like "Tomcat*" } | ForEach-Object {
        Stop-Service $_.Name -ErrorAction SilentlyContinue
        & cmd /c "`"C:\Tomcat10\bin\service.bat`" remove $($_.Name)" 2>&1 | Out-Null
    }
    Remove-Item "C:\Tomcat10" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  [OK] Entorno limpiado completamente." -ForegroundColor Green
}

function Flujo-Instalacion {
    param($tipo, $nombre)
    Write-Host ""
    Write-Host "  === Instalacion: $nombre ===" -ForegroundColor Cyan
    $puerto = Solicitar-Puerto
    Write-Host "  Puerto seleccionado: $puerto"; Write-Host ""
    $conf = Read-Host "  Confirmar instalacion de $nombre en puerto $puerto? [s/N]"
    if ($conf -notmatch '^[sS]$') { Write-Host "  Instalacion cancelada."; return }
    switch ($tipo) {
        "iis"    { Instalar-IIS    -puerto $puerto }
        "apache" { Instalar-Apache -puerto $puerto }
        "nginx"  { Instalar-Nginx  -puerto $puerto }
        "tomcat" { Instalar-Tomcat -puerto $puerto }
    }
}
