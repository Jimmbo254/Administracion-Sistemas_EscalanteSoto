# =============================================================================
# aprovisionamiento_http.ps1 - Aprovisionamiento HTTP en Windows Server 2022
# Uso: Ejecutar como Administrador en PowerShell
# Servidores: IIS, Apache (ZIP), Nginx (ZIP), Tomcat (ZIP)
# IP VM: 192.168.56.102
# =============================================================================

$VM_IP    = "192.168.56.102"
$ZIP_BASE = "C:\"

$APACHE_VERSIONES = @(
    @{ num = "1"; version = "2.4.66"; etiqueta = "Latest";  zipNombreReal = "httpd-2.4.66-260223-Win64-VS18.zip"; url = "https://home.apache.org/~wrowe/vs18/httpd-2.4.66-260223-Win64-VS18.zip" },
    @{ num = "2"; version = "2.4.65"; etiqueta = "Stable";  zipNombreReal = "httpd-2.4.65-250724-Win64-VS18.zip"; url = "https://home.apache.org/~wrowe/vs18/httpd-2.4.65-250724-Win64-VS18.zip" },
    @{ num = "3"; version = "2.4.64"; etiqueta = "Legacy";  zipNombreReal = "httpd-2.4.64-250710-Win64-VS18.zip"; url = "https://home.apache.org/~wrowe/vs18/httpd-2.4.64-250710-Win64-VS18.zip" }
)

$NGINX_VERSIONES = @(
    @{ num = "1"; version = "1.27.4"; etiqueta = "Mainline";   url = "https://nginx.org/download/nginx-1.27.4.zip" },
    @{ num = "2"; version = "1.26.3"; etiqueta = "Stable";     url = "https://nginx.org/download/nginx-1.26.3.zip" },
    @{ num = "3"; version = "1.24.0"; etiqueta = "Legacy";     url = "https://nginx.org/download/nginx-1.24.0.zip" }
)

$TOMCAT_VERSIONES = @(
    @{ num = "1"; version = "11.0.4";  etiqueta = "Latest";     url = "https://archive.apache.org/dist/tomcat/tomcat-11/v11.0.4/bin/apache-tomcat-11.0.4-windows-x64.zip" },
    @{ num = "2"; version = "10.1.39"; etiqueta = "Stable";     url = "https://archive.apache.org/dist/tomcat/tomcat-10/v10.1.39/bin/apache-tomcat-10.1.39-windows-x64.zip" },
    @{ num = "3"; version = "9.0.102"; etiqueta = "LTS/Legacy"; url = "https://archive.apache.org/dist/tomcat/tomcat-9/v9.0.102/bin/apache-tomcat-9.0.102-windows-x64.zip" }
)

$PUERTOS_RESERVADOS = @(1,7,9,11,13,15,17,19,20,21,22,23,25,37,42,43,53,69,
    77,79,110,111,113,115,117,118,119,123,135,137,139,143,161,177,179,389,
    427,445,465,512,513,514,515,526,530,531,532,540,548,554,556,563,587,
    601,636,989,990,993,995,1723,2049,2222,3306,3389,5432)

$SERVICIOS_RESERVADOS = @{
    20="FTP-Data"; 21="FTP"; 22="SSH"; 25="SMTP"; 53="DNS"
    110="POP3"; 143="IMAP"; 445="SMB"; 2222="SSH-Alt"
    3306="MySQL"; 5432="PostgreSQL"; 3389="RDP"
}

# =============================================================================
# VERIFICAR ADMINISTRADOR
# =============================================================================

$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ""
    Write-Host "  [ERROR] Este script requiere privilegios de Administrador." -ForegroundColor Red
    Write-Host "  Click derecho en PowerShell -> 'Ejecutar como administrador'" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Presiona Enter para salir"
    exit 1
}

Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process -Force -ErrorAction SilentlyContinue

# =============================================================================
# UTILIDADES
# =============================================================================

function Solicitar-Puerto {
    param([string]$ServicioNombre = "el servicio")
    while ($true) {
        $input_p = Read-Host "  Puerto para $ServicioNombre (ej. 80, 8080, 9090)"
        if ($input_p -notmatch '^\d+$') { Write-Host "  [!] Solo numeros." -ForegroundColor Red; continue }
        $p = [int]$input_p
        if ($p -le 0 -or $p -gt 65535) { Write-Host "  [!] Puerto fuera de rango (1-65535)." -ForegroundColor Red; continue }
        if ($PUERTOS_RESERVADOS -contains $p) {
            $desc = if ($SERVICIOS_RESERVADOS.ContainsKey($p)) { $SERVICIOS_RESERVADOS[$p] } else { "Sistema Critico" }
            Write-Host "  [!] Puerto $p reservado para $desc. Elige otro." -ForegroundColor Red
            continue
        }
        if (netstat -ano 2>$null | Select-String ":$p ") { Write-Host "  [!] Puerto $p ya esta en uso." -ForegroundColor Red; continue }
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
  <title>$Servicio - Puerto $Puerto</title>
</head>
<body>
  <h1>Servidor Activo</h1>
  <p><strong>Servidor:</strong> $Servicio</p>
  <p><strong>Version:</strong> $Version</p>
  <p><strong>Puerto:</strong> $Puerto</p>
  <p><strong>IP:</strong> $VM_IP</p>
  <p>URL: http://${VM_IP}:${Puerto}</p>
</body>
</html>
"@
    $html | Out-File "$Ruta\index.html" -Encoding utf8
}

function Configurar-Firewall {
    param([int]$Puerto, [string]$Nombre)
    Write-Host "  [*] Abriendo puerto $Puerto en firewall..." -ForegroundColor DarkGray
    $ruleName = "WebServer_${Nombre}_${Puerto}"
    Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $ruleName `
        -Direction Inbound -Protocol TCP -LocalPort $Puerto `
        -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
    Write-Host "  [OK] Puerto $Puerto habilitado en firewall." -ForegroundColor Green
}

function Verificar-Servicio {
    param([string]$Servicio, [int]$Puerto)
    Write-Host ""
    Write-Host "  +------ Verificacion: $Servicio en puerto $Puerto ------+" -ForegroundColor Cyan

    $svc = Get-Service -Name $Servicio -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Write-Host "  [OK] Servicio $Servicio : ACTIVO" -ForegroundColor Green
    } elseif ($svc) {
        Write-Host "  [!!] Servicio $Servicio : $($svc.Status)" -ForegroundColor Red
    } else {
        Write-Host "  [--] $Servicio : proceso standalone (no como servicio Windows)" -ForegroundColor Yellow
    }

    if (netstat -ano 2>$null | Select-String ":$Puerto ") {
        Write-Host "  [OK] Puerto $Puerto : ESCUCHANDO" -ForegroundColor Green
    } else {
        Write-Host "  [??] Puerto $Puerto : no detectado aun" -ForegroundColor Yellow
    }

    Write-Host "  [>>] Encabezados HTTP (curl -I http://localhost:$Puerto):" -ForegroundColor Cyan
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:$Puerto" -UseBasicParsing -TimeoutSec 6 -ErrorAction Stop
        Write-Host "       HTTP $($resp.StatusCode) OK" -ForegroundColor Green
        $resp.Headers.GetEnumerator() | Where-Object { $_.Key -match "Server|X-Frame|X-Content|X-XSS" } | ForEach-Object {
            Write-Host "       $($_.Key): $($_.Value)" -ForegroundColor Gray
        }
    } catch {
        Write-Host "       (Sin respuesta - el servicio puede estar iniciando)" -ForegroundColor Yellow
    }
    Write-Host "  +---------------------------------------------------+" -ForegroundColor Cyan
}

function Descargar-ZIP {
    param([string]$Url, [string]$Destino, [string]$Nombre)
    Write-Host "  [*] Descargando $Nombre..." -ForegroundColor Cyan
    Write-Host "      Desde : $Url" -ForegroundColor DarkGray
    Write-Host "      Hacia : $Destino" -ForegroundColor DarkGray
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($Url, $Destino)
        if (Test-Path $Destino) {
            $mb = [math]::Round((Get-Item $Destino).Length / 1MB, 1)
            Write-Host "  [OK] Descargado correctamente ($mb MB)." -ForegroundColor Green
            return $true
        } else {
            Write-Host "  [!] El archivo no se guardo correctamente." -ForegroundColor Red
            return $false
        }
    } catch {
        Write-Host "  [!] Error al descargar: $_" -ForegroundColor Red
        return $false
    }
}

function Seleccionar-Version {
    param([array]$Versiones, [string]$NombreServidor)
    Write-Host ""
    Write-Host "  Versiones disponibles para $NombreServidor :" -ForegroundColor White

    foreach ($v in $Versiones) {
        $zipNombre = if ($NombreServidor -match "Tomcat") { "apache-tomcat-$($v.version).zip" }
                     elseif ($NombreServidor -match "Apache") { "apache_$($v.version).zip" }
                     else { "nginx_$($v.version).zip" }
        $estado = if (Test-Path "${ZIP_BASE}${zipNombre}") { "[LOCAL]" } else { "[se descargara]" }
        Write-Host "    $($v.num)) $NombreServidor $($v.version)  ($($v.etiqueta))  $estado"
    }
    Write-Host ""

    while ($true) {
        $sel = Read-Host "  Selecciona la version (1-$($Versiones.Count))"
        if ($sel -notmatch '^\d+$') { Write-Host "  [!] Solo el numero." -ForegroundColor Red; continue }
        $entrada = $Versiones | Where-Object { $_.num -eq $sel } | Select-Object -First 1
        if ($entrada) {
            # Nombre final con el que el script guarda y busca el ZIP
            $zipNombreFinal = if ($NombreServidor -match "Tomcat") { "apache-tomcat-$($entrada.version).zip" }
                              elseif ($NombreServidor -match "Apache") { "apache_$($entrada.version).zip" }
                              else { "nginx_$($entrada.version).zip" }
            $zipPath = "${ZIP_BASE}${zipNombreFinal}"

            if (-not (Test-Path $zipPath)) {
                # Para Apache usamos el nombre real del ZIP de ApacheLounge como destino temporal
                $urlDestino = if ($entrada.zipNombreReal) { "${ZIP_BASE}$($entrada.zipNombreReal)" } else { $zipPath }
                $ok = Descargar-ZIP -Url $entrada.url -Destino $urlDestino -Nombre "$NombreServidor $($entrada.version)"
                if (-not $ok) { return $null }
                # Renombrar al nombre estándar que usa el script
                if ($urlDestino -ne $zipPath -and (Test-Path $urlDestino)) {
                    Rename-Item -Path $urlDestino -NewName (Split-Path $zipPath -Leaf) -ErrorAction SilentlyContinue
                }
            }
            return $entrada.version
        }
        Write-Host "  [!] Opcion invalida (1-$($Versiones.Count))." -ForegroundColor Red
    }
}

# =============================================================================
# INSTALAR IIS
# =============================================================================

function Instalar-IIS {
    param([int]$Puerto)
    Write-Host ""
    Write-Host "  [*] Instalando IIS en puerto $Puerto..." -ForegroundColor Cyan

    $feature = Get-WindowsFeature -Name Web-Server -ErrorAction SilentlyContinue
    if (-not $feature.Installed) {
        Write-Host "  [*] Instalando rol Web-Server (IIS)..." -ForegroundColor DarkGray
        Install-WindowsFeature -Name Web-Server,Web-Common-Http,Web-Http-Errors, `
            Web-Static-Content,Web-Http-Logging,Web-Security `
            -IncludeManagementTools -ErrorAction Stop | Out-Null
    }

    Import-Module WebAdministration -ErrorAction Stop

    if (Get-Website -Name "Default Web Site" -ErrorAction SilentlyContinue) {
        Stop-Website -Name "Default Web Site" -ErrorAction SilentlyContinue
    }

    $siteName = "IIS_Puerto_$Puerto"
    $webRoot  = "C:\inetpub\wwwroot\$siteName"

    if (Get-Website -Name $siteName -ErrorAction SilentlyContinue) {
        Stop-Website  -Name $siteName -ErrorAction SilentlyContinue
        Remove-Website -Name $siteName -ErrorAction SilentlyContinue
    }

    New-Item -Path $webRoot -ItemType Directory -Force | Out-Null

    $iisVersion = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" -ErrorAction SilentlyContinue).VersionString
    if (-not $iisVersion) { $iisVersion = "10.0" }

    Crear-Index -Ruta $webRoot -Servicio "IIS (Internet Information Services)" `
                -Version $iisVersion -Puerto $Puerto

    $webconfig = @"
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <httpProtocol>
      <customHeaders>
        <remove name="X-Powered-By" />
        <add name="X-Frame-Options" value="SAMEORIGIN" />
        <add name="X-Content-Type-Options" value="nosniff" />
        <add name="X-XSS-Protection" value="1; mode=block" />
      </customHeaders>
    </httpProtocol>
    <security>
      <requestFiltering removeServerHeader="true">
        <verbs allowUnlisted="false">
          <add verb="GET"  allowed="true" />
          <add verb="POST" allowed="true" />
          <add verb="HEAD" allowed="true" />
        </verbs>
      </requestFiltering>
    </security>
  </system.webServer>
</configuration>
"@
    $webconfig | Out-File "$webRoot\web.config" -Encoding utf8

    New-Website -Name $siteName -Port $Puerto -PhysicalPath $webRoot -Force | Out-Null
    Start-Website -Name $siteName -ErrorAction SilentlyContinue
    Start-Service -Name W3SVC -ErrorAction SilentlyContinue
    Configurar-Firewall -Puerto $Puerto -Nombre "IIS"

    $i = 0
    while ($i -lt 15) { Start-Sleep -Seconds 1; if (netstat -ano 2>$null | Select-String ":$Puerto ") { break }; $i++ }

    Write-Host ""
    Write-Host "  +==================================================+" -ForegroundColor Green
    Write-Host "  |  [OK] IIS activo                                 |" -ForegroundColor Green
    Write-Host "  |  URL : http://${VM_IP}:${Puerto}                 |" -ForegroundColor Green
    Write-Host "  |  Version IIS: $iisVersion                        |" -ForegroundColor Green
    Write-Host "  +==================================================+" -ForegroundColor Green
    Verificar-Servicio -Servicio "W3SVC" -Puerto $Puerto
}

# =============================================================================
# INSTALAR APACHE
# =============================================================================

function _Instalar-VCRedist {
    $vcDll = Get-ChildItem "C:\Windows\System32\VCRUNTIME140.dll" -ErrorAction SilentlyContinue
    if ($vcDll) { Write-Host "  [OK] VCRUNTIME140.dll encontrado." -ForegroundColor DarkGray; return }

    Write-Host "  [!] VCRUNTIME140.dll no encontrado." -ForegroundColor Yellow
    Write-Host "  [*] Descargando Visual C++ Redistributable 2015-2022 (x64)..." -ForegroundColor Cyan

    $vcUrl = "https://aka.ms/vs/17/release/vc_redist.x64.exe"
    $vcExe = "$env:TEMP\vc_redist.x64.exe"

    try {
        Invoke-WebRequest -Uri $vcUrl -OutFile $vcExe -UseBasicParsing -ErrorAction Stop
        $p = Start-Process -FilePath $vcExe -ArgumentList "/install /quiet /norestart" -Wait -PassThru
        Remove-Item $vcExe -Force -ErrorAction SilentlyContinue
        if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) {
            Write-Host "  [OK] VC++ Redistributable instalado." -ForegroundColor Green
        } else {
            Write-Host "  [!] Instalacion termino con codigo $($p.ExitCode)." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  [!] No se pudo descargar VC++ Redistributable: $_" -ForegroundColor Red
        Write-Host "       Descarga manual: https://aka.ms/vs/17/release/vc_redist.x64.exe" -ForegroundColor Yellow
    }
}

function Instalar-Apache-Win {
    param([int]$Puerto)
    Write-Host ""
    Write-Host "  [*] Aprovisionamiento de Apache HTTP Server" -ForegroundColor Cyan

    $version = Seleccionar-Version -Versiones $APACHE_VERSIONES -NombreServidor "Apache"
    if (-not $version) { return }

    $zipPath  = "${ZIP_BASE}apache_${version}.zip"
    $destBase = "C:\apache_$version"

    Get-Process -Name "httpd" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    if (Test-Path $destBase) { Remove-Item -Path $destBase -Recurse -Force -ErrorAction SilentlyContinue }

    Write-Host "  [*] Extrayendo $zipPath..." -ForegroundColor DarkGray
    try { Expand-Archive -Path $zipPath -DestinationPath $ZIP_BASE -Force -ErrorAction Stop }
    catch { Write-Host "  [!] Error al extraer: $_" -ForegroundColor Red; return }

    foreach ($c in @("C:\Apache24", "C:\Apache24-$version", "C:\Apache_$version")) {
        if ((Test-Path $c) -and ($c -ne $destBase)) {
            Rename-Item -Path $c -NewName "apache_$version" -ErrorAction SilentlyContinue; break
        }
    }

    if (-not (Test-Path $destBase)) { Write-Host "  [!] No se encontro $destBase tras extraer." -ForegroundColor Red; return }

    $conf = "$destBase\conf\httpd.conf"
    if (-not (Test-Path $conf)) { Write-Host "  [!] httpd.conf no encontrado." -ForegroundColor Red; return }

    Write-Host "  [*] Configurando puerto y hardening en httpd.conf..." -ForegroundColor DarkGray
    $c = Get-Content $conf
    $c = $c -replace '^Listen\s+\d+',           "Listen $Puerto"
    $c = $c -replace '^#?ServerName\s+.*',      "ServerName localhost:$Puerto"
    $c = $c -replace '^#?ServerTokens\s+.*',    "ServerTokens Prod"
    $c = $c -replace '^#?ServerSignature\s+.*', "ServerSignature Off"
    $c = $c -replace '^#?TraceEnable\s+.*',     "TraceEnable Off"
    $c = $c -replace '#LoadModule headers_module', 'LoadModule headers_module'
    $srootFwd = $destBase -replace '\\', '/'
    $c = $c -replace 'Define SRVROOT ".*"', "Define SRVROOT `"$srootFwd`""
    $c | Set-Content $conf -Encoding UTF8

    if (-not (Select-String -Path $conf -Pattern "X-Frame-Options" -Quiet)) {
        Add-Content $conf ""
        Add-Content $conf "# Security Headers"
        Add-Content $conf '<IfModule mod_headers.c>'
        Add-Content $conf '    Header always set X-Frame-Options "SAMEORIGIN"'
        Add-Content $conf '    Header always set X-Content-Type-Options "nosniff"'
        Add-Content $conf '    Header always set X-XSS-Protection "1; mode=block"'
        Add-Content $conf '</IfModule>'
    }

    $htdocs = "$destBase\htdocs"
    if (-not (Test-Path $htdocs)) { New-Item $htdocs -ItemType Directory -Force | Out-Null }
    Crear-Index -Ruta $htdocs -Servicio "Apache HTTP Server (Windows)" -Version $version -Puerto $Puerto
    Configurar-Firewall -Puerto $Puerto -Nombre "Apache"
    _Instalar-VCRedist

    Write-Host "  [*] Iniciando Apache $version en puerto $Puerto..." -ForegroundColor DarkGray
    $proc = Start-Process -FilePath "$destBase\bin\httpd.exe" `
                          -WorkingDirectory "$destBase\bin" `
                          -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2

    if ($proc.HasExited) {
        Write-Host "  [!] httpd.exe termino inesperadamente (codigo: $($proc.ExitCode))." -ForegroundColor Red
        Write-Host "  [!] Causa probable: falta VCRUNTIME140.dll o error en httpd.conf" -ForegroundColor Yellow
        $errLog = "$destBase\logs\error.log"
        if (Test-Path $errLog) {
            Write-Host "  --- Ultimas lineas de error.log ---" -ForegroundColor Yellow
            Get-Content $errLog -Tail 10 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        }
        return
    }

    $i = 0
    while ($i -lt 10) { Start-Sleep -Seconds 1; if (netstat -ano 2>$null | Select-String ":$Puerto ") { break }; $i++ }

    if (netstat -ano 2>$null | Select-String ":$Puerto ") {
        Write-Host ""
        Write-Host "  +==================================================+" -ForegroundColor Green
        Write-Host "  |  [OK] Apache activo                              |" -ForegroundColor Green
        Write-Host "  |  URL : http://${VM_IP}:${Puerto}                 |" -ForegroundColor Green
        Write-Host "  |  Version: $version                               |" -ForegroundColor Green
        Write-Host "  +==================================================+" -ForegroundColor Green
    } else {
        Write-Host "  [!] Apache inicio pero el puerto $Puerto no responde." -ForegroundColor Yellow
        Write-Host "       Revisa: $destBase\logs\error.log" -ForegroundColor Yellow
    }
    Verificar-Servicio -Servicio "httpd" -Puerto $Puerto
}

# =============================================================================
# INSTALAR NGINX
# =============================================================================

function Instalar-Nginx-Win {
    param([int]$Puerto)
    Write-Host ""
    Write-Host "  [*] Aprovisionamiento de Nginx Web Server" -ForegroundColor Cyan

    $version = Seleccionar-Version -Versiones $NGINX_VERSIONES -NombreServidor "Nginx"
    if (-not $version) { return }

    $zipPath  = "${ZIP_BASE}nginx_${version}.zip"
    $destBase = "C:\nginx_$version"

    Get-Process -Name "nginx" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    if (Test-Path $destBase) { Remove-Item -Path $destBase -Recurse -Force -ErrorAction SilentlyContinue }

    Write-Host "  [*] Extrayendo $zipPath..." -ForegroundColor DarkGray
    try { Expand-Archive -Path $zipPath -DestinationPath $ZIP_BASE -Force -ErrorAction Stop }
    catch { Write-Host "  [!] Error al extraer: $_" -ForegroundColor Red; return }

    foreach ($c in @("C:\nginx-$version", "C:\nginx$version")) {
        if ((Test-Path $c) -and ($c -ne $destBase)) {
            Rename-Item -Path $c -NewName "nginx_$version" -ErrorAction SilentlyContinue; break
        }
    }

    if (-not (Test-Path $destBase)) { Write-Host "  [!] No se encontro $destBase tras extraer." -ForegroundColor Red; return }

    $htmlDir    = "$destBase\html"
    if (-not (Test-Path $htmlDir)) { New-Item $htmlDir -ItemType Directory -Force | Out-Null }
    $htmlDirFwd = $htmlDir -replace '\\', '/'

    $nginxConf = @"
worker_processes 1;
events { worker_connections 1024; }
http {
    include      mime.types;
    default_type application/octet-stream;
    server_tokens off;
    sendfile on;
    keepalive_timeout 65;
    server {
        listen $Puerto;
        server_name localhost;
        root $htmlDirFwd;
        index index.html;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
        if (`$request_method !~ ^(GET|POST|HEAD)`$) { return 405; }
        location / { try_files `$uri `$uri/ =404; }
    }
}
"@
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText("$destBase\conf\nginx.conf", $nginxConf, $utf8NoBom)

    Crear-Index -Ruta $htmlDir -Servicio "Nginx (Windows)" -Version $version -Puerto $Puerto
    Configurar-Firewall -Puerto $Puerto -Nombre "Nginx"

    Write-Host "  [*] Validando nginx.conf..." -ForegroundColor DarkGray
    $testResult = & "$destBase\nginx.exe" -t -p "$destBase" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [!] Error en nginx.conf:" -ForegroundColor Red
        $testResult | ForEach-Object { Write-Host "      $_" -ForegroundColor Yellow }
        return
    }
    Write-Host "  [OK] nginx.conf valido." -ForegroundColor DarkGray

    Write-Host "  [*] Iniciando Nginx $version en puerto $Puerto..." -ForegroundColor DarkGray
    $proc = Start-Process -FilePath "$destBase\nginx.exe" -WorkingDirectory $destBase -PassThru
    Start-Sleep -Seconds 2

    if ($proc.HasExited) {
        Write-Host "  [!] nginx.exe termino inesperadamente." -ForegroundColor Red
        $errLog = "$destBase\logs\error.log"
        if (Test-Path $errLog) {
            Write-Host "  --- Ultimas lineas de error.log ---" -ForegroundColor Yellow
            Get-Content $errLog -Tail 10 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        }
        return
    }

    $i = 0
    while ($i -lt 10) { Start-Sleep -Seconds 1; if (netstat -ano 2>$null | Select-String ":$Puerto ") { break }; $i++ }

    if (netstat -ano 2>$null | Select-String ":$Puerto ") {
        Write-Host ""
        Write-Host "  +==================================================+" -ForegroundColor Green
        Write-Host "  |  [OK] Nginx activo                               |" -ForegroundColor Green
        Write-Host "  |  URL : http://${VM_IP}:${Puerto}                 |" -ForegroundColor Green
        Write-Host "  |  Version: $version                               |" -ForegroundColor Green
        Write-Host "  +==================================================+" -ForegroundColor Green
    } else {
        Write-Host "  [!] Nginx inicio pero el puerto $Puerto no responde." -ForegroundColor Yellow
        $errLog = "$destBase\logs\error.log"
        if (Test-Path $errLog) {
            Write-Host "  --- Ultimas lineas de error.log ---" -ForegroundColor Yellow
            Get-Content $errLog -Tail 10 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        }
    }
    Verificar-Servicio -Servicio "nginx" -Puerto $Puerto
}

# =============================================================================
# INSTALAR TOMCAT
# =============================================================================

function _Instalar-Java {
    # Retorna el path del ejecutable java si esta disponible
    $java = Get-Command java -ErrorAction SilentlyContinue
    if ($java) {
        Write-Host "  [OK] Java detectado: $($java.Source)" -ForegroundColor DarkGray
        return $java
    }

    # Buscar en rutas comunes aunque no este en PATH
    $rutas = @(
        "$env:ProgramFiles\Eclipse Adoptium",
        "$env:ProgramFiles\Microsoft",
        "$env:ProgramFiles\Java",
        "$env:ProgramFiles\OpenJDK"
    )
    foreach ($r in $rutas) {
        $javaExe = Get-ChildItem "$r\*\bin\java.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($javaExe) {
            Write-Host "  [OK] Java encontrado en $($javaExe.FullName) (no estaba en PATH)." -ForegroundColor DarkGray
            $env:JAVA_HOME = $javaExe.Directory.Parent.FullName
            $env:PATH = "$($javaExe.DirectoryName);$env:PATH"
            return (Get-Command java -ErrorAction SilentlyContinue)
        }
    }

    # No esta instalado - ofrecer instalacion automatica
    Write-Host "  [!] Java no encontrado en el sistema." -ForegroundColor Yellow
    Write-Host "  [*] Se descargara OpenJDK 21 (Microsoft Build, ~180 MB)..." -ForegroundColor Cyan
    $confirm = Read-Host "  Instalar Java automaticamente? (s/n)"
    if ($confirm -notmatch '^[sS]$') {
        Write-Host "  [!] Tomcat requiere Java. Instalacion cancelada." -ForegroundColor Red
        return $null
    }

    $jdkUrl  = "https://aka.ms/download-jdk/microsoft-jdk-21-windows-x64.msi"
    $jdkMsi  = "$env:TEMP\microsoft-jdk-21.msi"

    Write-Host "  [*] Descargando OpenJDK 21..." -ForegroundColor DarkGray
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($jdkUrl, $jdkMsi)
    } catch {
        Write-Host "  [!] Error al descargar Java: $_" -ForegroundColor Red
        Write-Host "       Descarga manual: https://adoptium.net/" -ForegroundColor Yellow
        return $null
    }

    Write-Host "  [*] Instalando OpenJDK 21 (silencioso)..." -ForegroundColor DarkGray
    $p = Start-Process msiexec -ArgumentList "/i `"$jdkMsi`" /quiet /norestart ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJarFileRunWith,FeatureJavaHome" -Wait -PassThru
    Remove-Item $jdkMsi -Force -ErrorAction SilentlyContinue

    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        Write-Host "  [!] Instalacion de Java termino con codigo $($p.ExitCode)." -ForegroundColor Red
        return $null
    }

    # Refrescar PATH desde el registro para encontrar java sin reiniciar
    $machinePath = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    $userPath    = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $env:PATH    = "$machinePath;$userPath"

    $java = Get-Command java -ErrorAction SilentlyContinue
    if ($java) {
        Write-Host "  [OK] OpenJDK 21 instalado correctamente." -ForegroundColor Green
        return $java
    }

    # Si aun no esta en PATH buscar manualmente
    foreach ($r in $rutas) {
        $javaExe = Get-ChildItem "$r\*\bin\java.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($javaExe) {
            $env:JAVA_HOME = $javaExe.Directory.Parent.FullName
            $env:PATH = "$($javaExe.DirectoryName);$env:PATH"
            Write-Host "  [OK] Java localizado en $($javaExe.FullName)" -ForegroundColor Green
            return (Get-Command java -ErrorAction SilentlyContinue)
        }
    }

    Write-Host "  [!] Java instalado pero no detectable. Cierra y vuelve a abrir PowerShell." -ForegroundColor Yellow
    return $null
}

function Instalar-Tomcat-Win {
    param([int]$Puerto)
    Write-Host ""
    Write-Host "  [*] Aprovisionamiento de Apache Tomcat" -ForegroundColor Cyan

    $java = _Instalar-Java
    if (-not $java) { return }

    $version = Seleccionar-Version -Versiones $TOMCAT_VERSIONES -NombreServidor "Tomcat"
    if (-not $version) { return }

    $zipPath  = "${ZIP_BASE}apache-tomcat-${version}.zip"
    $destBase = "C:\tomcat_$version"

    Get-Service | Where-Object { $_.Name -like "Tomcat*" } | ForEach-Object {
        Stop-Service $_.Name -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
    if (Test-Path $destBase) { Remove-Item -Path $destBase -Recurse -Force -ErrorAction SilentlyContinue }

    Write-Host "  [*] Extrayendo $zipPath..." -ForegroundColor DarkGray
    try { Expand-Archive -Path $zipPath -DestinationPath $ZIP_BASE -Force -ErrorAction Stop }
    catch { Write-Host "  [!] Error al extraer: $_" -ForegroundColor Red; return }

    foreach ($c in @("C:\apache-tomcat-$version", "C:\tomcat-$version")) {
        if ((Test-Path $c) -and ($c -ne $destBase)) {
            Rename-Item -Path $c -NewName "tomcat_$version" -ErrorAction SilentlyContinue; break
        }
    }

    if (-not (Test-Path $destBase)) { Write-Host "  [!] No se encontro $destBase tras extraer." -ForegroundColor Red; return }

    $serverXml = "$destBase\conf\server.xml"
    if (-not (Test-Path $serverXml)) { Write-Host "  [!] server.xml no encontrado." -ForegroundColor Red; return }

    Write-Host "  [*] Configurando puerto $Puerto en server.xml..." -ForegroundColor DarkGray
    $xml = Get-Content $serverXml -Raw
    $xml = $xml -replace 'port="8080"', "port=`"$Puerto`""
    $xml = $xml -replace '(Connector port="' + $Puerto + '")', '$1 server="Apache"'
    $xml | Set-Content $serverXml -Encoding UTF8

    $webRoot = "$destBase\webapps\ROOT"
    New-Item -Path $webRoot -ItemType Directory -Force | Out-Null
    Crear-Index -Ruta $webRoot -Servicio "Apache Tomcat (Windows)" -Version $version -Puerto $Puerto
    Configurar-Firewall -Puerto $Puerto -Nombre "Tomcat"

    $env:CATALINA_HOME = $destBase
    if (-not $env:JAVA_HOME) {
        $env:JAVA_HOME = (Split-Path (Split-Path $java.Source))
    }

    $svcName    = "Tomcat_$Puerto"
    $serviceBat = "$destBase\bin\service.bat"
    if (Test-Path $serviceBat) {
        Write-Host "  [*] Registrando como servicio Windows ($svcName)..." -ForegroundColor DarkGray
        & cmd /c "`"$serviceBat`" install $svcName" 2>&1 | Out-Null
        Start-Service -Name $svcName -ErrorAction SilentlyContinue
    } else {
        Write-Host "  [*] Iniciando Tomcat directamente (startup.bat)..." -ForegroundColor DarkGray
        Start-Process -FilePath "$destBase\bin\startup.bat" -WorkingDirectory "$destBase\bin" -WindowStyle Hidden
    }

    Write-Host "  [*] Esperando que Tomcat escuche en puerto $Puerto (hasta 20s)..." -ForegroundColor DarkGray
    $i = 0
    while ($i -lt 20) { Start-Sleep -Seconds 1; if (netstat -ano 2>$null | Select-String ":$Puerto ") { break }; $i++ }

    Write-Host ""
    Write-Host "  +==================================================+" -ForegroundColor Green
    Write-Host "  |  [OK] Tomcat activo                              |" -ForegroundColor Green
    Write-Host "  |  URL : http://${VM_IP}:${Puerto}                 |" -ForegroundColor Green
    Write-Host "  |  Version: $version                               |" -ForegroundColor Green
    Write-Host "  +==================================================+" -ForegroundColor Green
    Verificar-Servicio -Servicio $svcName -Puerto $Puerto
}

# =============================================================================
# DESINSTALAR SERVIDOR
# =============================================================================

function Desinstalar-Servidor {
    Write-Host ""
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |    Desinstalar servidor especifico       |" -ForegroundColor Cyan
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  1) IIS   2) Apache   3) Nginx   4) Tomcat"
    Write-Host ""
    $op = Read-Host "  Selecciona (1-4)"

    switch ($op) {
        "1" {
            Write-Host "  [*] Desinstalando IIS..." -ForegroundColor Yellow
            Stop-Service W3SVC -Force -ErrorAction SilentlyContinue
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            Get-Website -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "Default Web Site" } | ForEach-Object {
                Remove-Website -Name $_.Name -ErrorAction SilentlyContinue
            }
            Uninstall-WindowsFeature -Name Web-Server -IncludeManagementTools -ErrorAction SilentlyContinue | Out-Null
            Remove-Item "C:\inetpub\wwwroot\IIS_*" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  [OK] IIS desinstalado." -ForegroundColor Green
        }
        "2" {
            Write-Host "  [*] Deteniendo y eliminando Apache..." -ForegroundColor Yellow
            Get-Process -Name "httpd" -ErrorAction SilentlyContinue | Stop-Process -Force
            Get-ChildItem "C:\" -Filter "apache_*" -Directory | ForEach-Object {
                Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
            Write-Host "  [OK] Apache desinstalado." -ForegroundColor Green
        }
        "3" {
            Write-Host "  [*] Deteniendo y eliminando Nginx..." -ForegroundColor Yellow
            Get-Process -Name "nginx" -ErrorAction SilentlyContinue | Stop-Process -Force
            Get-ChildItem "C:\" -Filter "nginx_*" -Directory | ForEach-Object {
                Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
            Write-Host "  [OK] Nginx desinstalado." -ForegroundColor Green
        }
        "4" {
            Write-Host "  [*] Deteniendo y eliminando Tomcat..." -ForegroundColor Yellow
            Get-Service | Where-Object { $_.Name -like "Tomcat*" } | ForEach-Object {
                Stop-Service $_.Name -Force -ErrorAction SilentlyContinue
                $catHome = "C:\tomcat_" + ($_.Name -replace 'Tomcat_','')
                if (Test-Path "$catHome\bin\service.bat") {
                    $env:CATALINA_HOME = $catHome
                    & cmd /c "`"$catHome\bin\service.bat`" remove $($_.Name)" 2>&1 | Out-Null
                }
            }
            Get-ChildItem "C:\" -Filter "tomcat_*" -Directory | ForEach-Object {
                Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
            Write-Host "  [OK] Tomcat desinstalado." -ForegroundColor Green
        }
        default { Write-Host "  [!] Opcion invalida." -ForegroundColor Red }
    }
}

# =============================================================================
# LEVANTAR / REINICIAR SERVICIO
# =============================================================================

function Levantar-Servicio {
    Write-Host ""
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |    Levantar / Reiniciar servicio         |" -ForegroundColor Cyan
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan

    $instalados = @()
    if (Get-Service W3SVC -ErrorAction SilentlyContinue)                                   { $instalados += "1) IIS"    }
    if (Get-ChildItem "C:\" -Filter "apache_*" -Directory -ErrorAction SilentlyContinue)  { $instalados += "2) Apache" }
    if (Get-ChildItem "C:\" -Filter "nginx_*"  -Directory -ErrorAction SilentlyContinue)  { $instalados += "3) Nginx"  }
    if (Get-ChildItem "C:\" -Filter "tomcat_*" -Directory -ErrorAction SilentlyContinue)  { $instalados += "4) Tomcat" }

    if ($instalados.Count -eq 0) { Write-Host "  No hay ningun servidor instalado." -ForegroundColor Yellow; return }

    Write-Host "  Servidores detectados:"
    $instalados | ForEach-Object { Write-Host "    $_" }
    Write-Host ""

    $op     = Read-Host "  Selecciona (1-4)"
    $puerto = Solicitar-Puerto -ServicioNombre "reinicio"

    switch ($op) {
        "1" {
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            Configurar-Firewall -Puerto $puerto -Nombre "IIS"
            Restart-Service W3SVC -ErrorAction SilentlyContinue
            Write-Host "  [OK] IIS reiniciado en puerto $puerto." -ForegroundColor Green
            Verificar-Servicio -Servicio "W3SVC" -Puerto $puerto
        }
        "2" {
            $dir = Get-ChildItem "C:\" -Filter "apache_*" -Directory | Select-Object -Last 1
            if ($dir) {
                $conf = "$($dir.FullName)\conf\httpd.conf"
                (Get-Content $conf) -replace '^Listen\s+\d+', "Listen $puerto" | Set-Content $conf
                Get-Process -Name "httpd" -ErrorAction SilentlyContinue | Stop-Process -Force
                Start-Sleep -Seconds 1
                Start-Process -FilePath "$($dir.FullName)\bin\httpd.exe" -WorkingDirectory "$($dir.FullName)\bin" -WindowStyle Hidden
                Configurar-Firewall -Puerto $puerto -Nombre "Apache"
                Write-Host "  [OK] Apache reiniciado en puerto $puerto." -ForegroundColor Green
                Verificar-Servicio -Servicio "httpd" -Puerto $puerto
            }
        }
        "3" {
            $dir = Get-ChildItem "C:\" -Filter "nginx_*" -Directory | Select-Object -Last 1
            if ($dir) {
                $conf = "$($dir.FullName)\conf\nginx.conf"
                (Get-Content $conf) -replace 'listen\s+\d+;', "listen $puerto;" | Set-Content $conf
                Get-Process -Name "nginx" -ErrorAction SilentlyContinue | Stop-Process -Force
                Start-Sleep -Seconds 1
                Start-Process -FilePath "$($dir.FullName)\nginx.exe" -WorkingDirectory $dir.FullName
                Configurar-Firewall -Puerto $puerto -Nombre "Nginx"
                Write-Host "  [OK] Nginx reiniciado en puerto $puerto." -ForegroundColor Green
                Verificar-Servicio -Servicio "nginx" -Puerto $puerto
            }
        }
        "4" {
            $dir = Get-ChildItem "C:\" -Filter "tomcat_*" -Directory | Select-Object -Last 1
            if ($dir) {
                $xml = "$($dir.FullName)\conf\server.xml"
                (Get-Content $xml) -replace 'port="\d+"', "port=`"$puerto`"" | Set-Content $xml
                Get-Service | Where-Object { $_.Name -like "Tomcat*" } | Restart-Service -ErrorAction SilentlyContinue
                Configurar-Firewall -Puerto $puerto -Nombre "Tomcat"
                Write-Host "  [OK] Tomcat reiniciado en puerto $puerto." -ForegroundColor Green
                $svc = (Get-Service | Where-Object { $_.Name -like "Tomcat*" } | Select-Object -First 1).Name
                if ($svc) { Verificar-Servicio -Servicio $svc -Puerto $puerto }
            }
        }
        default { Write-Host "  [!] Opcion invalida." -ForegroundColor Red }
    }
}

# =============================================================================
# VERIFICACION MANUAL
# =============================================================================

function Flujo-Verificacion {
    Write-Host ""
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |    Verificacion de servicio activo       |" -ForegroundColor Cyan
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  1) IIS   2) Apache   3) Nginx   4) Tomcat"
    Write-Host ""
    $op     = Read-Host "  Selecciona el servicio (1-4)"
    $puerto = Read-Host "  Puerto del servicio"

    if ($puerto -notmatch '^\d+$') { Write-Host "  [!] Puerto invalido." -ForegroundColor Red; return }

    $svcName = switch ($op) {
        "1" { "W3SVC" }
        "2" { "httpd" }
        "3" { "nginx" }
        "4" { (Get-Service | Where-Object { $_.Name -like "Tomcat*" } | Select-Object -First 1).Name }
        default { Write-Host "  [!] Opcion invalida." -ForegroundColor Red; return }
    }
    Verificar-Servicio -Servicio $svcName -Puerto ([int]$puerto)
}

# =============================================================================
# LIMPIAR ENTORNO COMPLETO
# =============================================================================

function Limpiar-Entorno-Win {
    Write-Host ""
    Write-Host "  [*] Limpiando entorno completo..." -ForegroundColor Yellow

    Stop-Service W3SVC -Force -ErrorAction SilentlyContinue
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    Get-Website -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "Default Web Site" } | ForEach-Object {
        Remove-Website -Name $_.Name -ErrorAction SilentlyContinue
    }
    Remove-Item "C:\inetpub\wwwroot\IIS_*" -Recurse -Force -ErrorAction SilentlyContinue

    Get-Process -Name "httpd" -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Service | Where-Object { $_.Name -like "Apache*" } | Stop-Service -Force -ErrorAction SilentlyContinue
    Get-ChildItem "C:\" -Filter "apache_*" -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    Get-Process -Name "nginx" -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-ChildItem "C:\" -Filter "nginx_*" -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    Get-Service | Where-Object { $_.Name -like "Tomcat*" } | ForEach-Object {
        Stop-Service $_.Name -Force -ErrorAction SilentlyContinue
        $catHome = "C:\tomcat_" + ($_.Name -replace 'Tomcat_','')
        if (Test-Path "$catHome\bin\service.bat") {
            $env:CATALINA_HOME = $catHome
            & cmd /c "`"$catHome\bin\service.bat`" remove $($_.Name)" 2>&1 | Out-Null
        }
    }
    Get-ChildItem "C:\" -Filter "tomcat_*" -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    Get-NetFirewallRule | Where-Object { $_.DisplayName -match "^WebServer_" } | `
        Remove-NetFirewallRule -ErrorAction SilentlyContinue

    Write-Host "  [OK] Entorno limpiado." -ForegroundColor Green
}

# =============================================================================
# MENU PRINCIPAL
# =============================================================================

while ($true) {
    Write-Host ""
    Write-Host "  +=============================================+" -ForegroundColor Magenta
    Write-Host "  |    Aprovisionamiento HTTP Multi-Servidor    |" -ForegroundColor Magenta
    Write-Host "  |         Windows Server 2022                 |" -ForegroundColor Magenta
    Write-Host "  |         VM: $VM_IP                          |" -ForegroundColor Magenta
    Write-Host "  +=============================================+" -ForegroundColor Magenta
    Write-Host "  |  1) IIS     (Nativo de Windows Server)      |" -ForegroundColor White
    Write-Host "  |  2) Apache  (ZIP desde C:\)                 |" -ForegroundColor White
    Write-Host "  |  3) Nginx   (ZIP desde C:\)                 |" -ForegroundColor White
    Write-Host "  |  4) Tomcat  (ZIP desde C:\)                 |" -ForegroundColor White
    Write-Host "  |  5) Levantar / Reiniciar servicio           |" -ForegroundColor White
    Write-Host "  |  6) Desinstalar servidor                    |" -ForegroundColor White
    Write-Host "  |  7) Verificar servicio                      |" -ForegroundColor White
    Write-Host "  |  8) Limpiar entorno completo                |" -ForegroundColor White
    Write-Host "  |  9) Salir                                   |" -ForegroundColor White
    Write-Host "  +=============================================+" -ForegroundColor Magenta
    Write-Host ""

    $opcion = Read-Host "  Selecciona una opcion (1-9)"

    if ([string]::IsNullOrWhiteSpace($opcion) -or $opcion -notmatch '^[1-9]$') {
        Write-Host "  [!] Opcion invalida. Elige entre 1 y 9." -ForegroundColor Yellow
        continue
    }

    switch ($opcion) {
        "9" { Write-Host "  [*] Saliendo. Hasta luego!" -ForegroundColor Cyan; Write-Host ""; break }
        "8" { Limpiar-Entorno-Win; continue }
        "7" { Flujo-Verificacion; continue }
        "6" { Desinstalar-Servidor; continue }
        "5" { Levantar-Servicio; continue }
        default {
            $nombreServicio = switch ($opcion) {
                "1" { "IIS"    }
                "2" { "Apache" }
                "3" { "Nginx"  }
                "4" { "Tomcat" }
            }

            Write-Host ""
            Write-Host "  [*] Configurando: $nombreServicio" -ForegroundColor Cyan
            $puerto = Solicitar-Puerto -ServicioNombre $nombreServicio

            Write-Host ""
            Write-Host "      Servidor : $nombreServicio" -ForegroundColor White
            Write-Host "      Puerto   : $puerto"         -ForegroundColor White
            Write-Host "      URL      : http://${VM_IP}:${puerto}" -ForegroundColor White

            switch ($opcion) {
                "1" { Instalar-IIS        -Puerto $puerto }
                "2" { Instalar-Apache-Win -Puerto $puerto }
                "3" { Instalar-Nginx-Win  -Puerto $puerto }
                "4" { Instalar-Tomcat-Win -Puerto $puerto }
            }

            Write-Host ""
            Write-Host "  Verificacion desde tu maquina host:" -ForegroundColor Cyan
            Write-Host "    Navegador : http://${VM_IP}:${puerto}" -ForegroundColor White
            Write-Host "    PowerShell: Invoke-WebRequest http://${VM_IP}:${puerto}" -ForegroundColor White
            Write-Host ""

            $continuar = Read-Host "  Instalar otro servidor? (s/n)"
            if ($continuar -notmatch '^[sS]$') {
                Write-Host "  [*] Aprovisionamiento completado!" -ForegroundColor Green
                Write-Host ""
                break
            }
        }
    }

    if ($opcion -eq "9") { break }
}
