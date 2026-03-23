Import-Module WebAdministration -ErrorAction SilentlyContinue

$PUERTOS_BLOQUEADOS = @(1,7,9,11,13,15,17,19,20,21,22,23,25,37,42,43,53,69,77,79,
    87,95,101,102,103,104,109,110,111,113,115,117,119,123,135,139,142,143,179,389,
    465,512,513,514,515,526,530,531,532,540,548,554,556,563,587,601,636,993,995,
    2049,3659,4045,6000,6665,6666,6667,6668,6669,6697)

function Garantizar-Chocolatey {
    $chocoPath = "C:\ProgramData\chocolatey\bin\choco.exe"
    if (!(Test-Path $chocoPath)) {
        Write-Host "Chocolatey no detectado. Instalando..." -ForegroundColor Cyan
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:Path += ";C:\ProgramData\chocolatey\bin"
    }
    return "C:\ProgramData\chocolatey\bin\choco.exe"
}

function Limpiar-Entorno {
    param($Puerto)
    Write-Host "Limpiando servicios en puerto $Puerto..." -ForegroundColor Cyan
    Stop-Service nginx, Apache, Apache2.4, W3SVC, ftpsvc -Force -ErrorAction SilentlyContinue
    taskkill /F /IM nginx.exe /T 2>$null
    taskkill /F /IM httpd.exe /T 2>$null
    $con = Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue
    if ($con) { $con.OwningProcess | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } }
    Start-Sleep -Seconds 2
}

function Crear-Pagina {
    param($servicio, $puerto)
    $paths = @{
        "nginx"  = "C:\tools\nginx-1.29.6\html\index.html"
        "apache" = "C:\Users\vboxuser\AppData\Roaming\Apache24\htdocs\index.html"
        "iis"    = "C:\inetpub\wwwroot\index.html"
    }
    $path = $paths[$servicio]
    if (!$path) { return }
    $servidorNombre = $servicio.ToUpper()
    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } | Select-Object -First 1).IPAddress
    $html = @"
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<title>$servidorNombre</title>
</head>
<body>
  <h2>$servidorNombre</h2>
  <p>IP: $ip</p>
  <p>Puerto: $puerto</p>
  <p>Host: www.reprobados.com</p>
</body>
</html>
"@
    $dir = Split-Path $path
    if (!(Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
    Set-Content $path $html -Encoding UTF8
}

function Generar-Certificado-SSL {
    $dir = "C:\ssl\reprobados"
    $crt = "$dir\reprobados.crt"
    $key = "$dir\reprobados.key"
    if (!(Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
    $crtOk = (Test-Path $crt) -and ((Get-Content $crt -First 1) -like "-----BEGIN*")
    $keyOk = (Test-Path $key) -and ((Get-Content $key -First 1) -like "-----BEGIN*")
    if ($crtOk -and $keyOk) {
        Write-Host "Reutilizando certificado existente." -ForegroundColor Cyan
        return @{ CRT = $crt; KEY = $key; OK = $true }
    }
    $opensslPath = $null
    foreach ($c in @("C:\Program Files\Git\usr\bin\openssl.exe","C:\Program Files (x86)\Git\usr\bin\openssl.exe","C:\ProgramData\chocolatey\bin\openssl.exe")) {
        if (Test-Path $c) { $opensslPath = $c; break }
    }
    if (!$opensslPath) {
        $cmd = Get-Command openssl -ErrorAction SilentlyContinue
        if ($cmd) { $opensslPath = $cmd.Source }
    }
    if ($opensslPath) {
        Write-Host "Generando certificado SSL con OpenSSL..." -ForegroundColor Cyan
        & $opensslPath genrsa -out $key 2048 2>$null
        & $opensslPath req -new -x509 -key $key -out $crt -days 365 -subj "/C=MX/ST=Sinaloa/L=LosMochis/O=Reprobados/CN=www.reprobados.com" 2>$null
        Write-Host "CRT generado: $(Get-Content $crt -First 1)" -ForegroundColor Green
        Write-Host "KEY generado: $(Get-Content $key -First 1)" -ForegroundColor Green
        return @{ CRT = $crt; KEY = $key; OK = $true }
    } else {
        Write-Host "OpenSSL no encontrado. Solo IIS usara SSL." -ForegroundColor Red
        return @{ CRT = $crt; KEY = $key; OK = $false }
    }
}

function Obtener-CertObj {
    $certObj = Get-ChildItem "Cert:\LocalMachine\My" | Where-Object { $_.Subject -like "*reprobados*" } | Select-Object -First 1
    if (!$certObj) {
        $certObj = New-SelfSignedCertificate -DnsName "www.reprobados.com" -CertStoreLocation "Cert:\LocalMachine\My" -NotAfter (Get-Date).AddDays(365) -KeyExportPolicy Exportable
    }
    return $certObj
}

function Aplicar-Despliegue {
    param($Servicio)
    Write-Host ""
    $P_Ingresado = Read-Host "Puerto para $Servicio (ej. 8081, 8443, 9090)"
    if ($P_Ingresado -match '^\d+$') {
        $P = [int]$P_Ingresado
    } else {
        Write-Host "Puerto invalido, usando el configurado por defecto: $global:PUERTO_ACTUAL" -ForegroundColor Red
        $P = [int]$global:PUERTO_ACTUAL
    }
    if ($P -in $PUERTOS_BLOQUEADOS) {
        Write-Host "El puerto $P esta en la lista de bloqueados por navegadores." -ForegroundColor Red
        $confirma = Read-Host "Continuar de todos modos? [S/N]"
        if ($confirma -notmatch '^[Ss]$') { return }
    }
    $cert = Generar-Certificado-SSL
    $respSSL  = Read-Host "Activar SSL en este servicio? [S/N]"
    $usarSSL  = ($respSSL -match '^[Ss]$') -and $cert.OK
    $protocolo = if ($usarSSL) { "https" } else { "http" }
    Write-Host "SSL: $(if ($usarSSL) { 'ACTIVADO' } else { 'DESACTIVADO' })" -ForegroundColor $(if ($usarSSL) { 'Green' } else { 'Cyan' })
    Limpiar-Entorno $P

    switch ($Servicio) {
        "nginx" {
            $nginxExeItem = Get-ChildItem "C:\tools" -Recurse -Filter "nginx.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if (!$nginxExeItem) { Write-Host "nginx.exe no encontrado en C:\tools\nginx" -ForegroundColor Red; Pause; return }
            $nginxDir = $nginxExeItem.DirectoryName
            $conf     = "$nginxDir\conf\nginx.conf"
            $certAbs  = "C:/ssl/reprobados/reprobados.crt"
            $keyAbs   = "C:/ssl/reprobados/reprobados.key"
            if ($usarSSL) {
                $cfg = @"
worker_processes  1;
events { worker_connections 1024; }
http {
    include       mime.types;
    default_type  application/octet-stream;
    server {
        listen       80;
        server_name  www.reprobados.com;
        return 301   https://`$host:$P`$request_uri;
    }
    server {
        listen       $P ssl;
        server_name  www.reprobados.com;
        ssl_certificate      $certAbs;
        ssl_certificate_key  $keyAbs;
        add_header Strict-Transport-Security "max-age=31536000" always;
        location / { root html; index index.html; }
    }
}
"@
            } else {
                $cfg = @"
worker_processes  1;
events { worker_connections 1024; }
http {
    include       mime.types;
    default_type  application/octet-stream;
    server {
        listen       $P;
        server_name  www.reprobados.com;
        location / { root html; index index.html; }
    }
}
"@
            }
            Set-Content $conf $cfg -Encoding ASCII
            Crear-Pagina "nginx" $P
            Start-Process "$nginxDir\nginx.exe" -WorkingDirectory $nginxDir -WindowStyle Hidden
            Start-Sleep -Seconds 3
        }

        "apache" {
            $rutaApache = $null
            $svcWmi = Get-CimInstance Win32_Service | Where-Object { $_.Name -like "Apache*" } | Select-Object -First 1
            if ($svcWmi) {
                if ($svcWmi.PathName -match '"([^"]+bin[^"]+httpd\.exe)"') { $rutaApache = Split-Path (Split-Path $matches[1] -Parent) -Parent }
                elseif ($svcWmi.PathName -match '([A-Za-z]:[^ ]+httpd\.exe)') { $rutaApache = Split-Path (Split-Path $matches[1] -Parent) -Parent }
            }
            if (!$rutaApache) {
                foreach ($c in @("C:\Apache24","$env:APPDATA\Apache24")) {
                    if (Test-Path "$c\bin\httpd.exe") { $rutaApache = $c; break }
                }
            }
            if (!$rutaApache) { Write-Host "Apache no encontrado." -ForegroundColor Red; Pause; return }
            $conf    = "$rutaApache\conf\httpd.conf"
            $webRoot = "$rutaApache\htdocs"
            $certDir = "C:/ssl/reprobados"
            $webDir  = $webRoot -replace '\\','/'
            $lineas = Get-Content $conf
            for ($i = 0; $i -lt $lineas.Count; $i++) {
                if ($lineas[$i] -match '^<VirtualHost') { $lineas = $lineas[0..($i-1)]; break }
            }
            $lineas = $lineas | Where-Object { $_ -notmatch '^Listen ' }
            $lineas = $lineas | ForEach-Object {
                if ($_ -match '^#?ServerName ') { "ServerName www.reprobados.com:$P" }
                elseif ($_ -match '^#LoadModule ssl_module') { "LoadModule ssl_module modules/mod_ssl.so" }
                elseif ($_ -match '^#LoadModule socache_shmcb_module') { "LoadModule socache_shmcb_module modules/mod_socache_shmcb.so" }
                elseif ($_ -match '^#LoadModule headers_module') { "LoadModule headers_module modules/mod_headers.so" }
                else { $_ }
            }
            if ($usarSSL) { $lineas = @("Listen 80", "Listen $P") + $lineas }
            else { $lineas = @("Listen $P") + $lineas }
            if ($usarSSL) {
                $vhost = @"

<VirtualHost *:80>
    ServerName www.reprobados.com
    Redirect permanent / https://www.reprobados.com:$P/
</VirtualHost>

<VirtualHost *:$P>
    ServerName www.reprobados.com
    DocumentRoot "$webDir"
    SSLEngine on
    SSLCertificateFile    "$certDir/reprobados.crt"
    SSLCertificateKeyFile "$certDir/reprobados.key"
    Header always set Strict-Transport-Security "max-age=31536000"
    <Directory "$webDir">
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
"@
            } else {
                $vhost = @"
<VirtualHost *:$P>
    ServerName www.reprobados.com
    DocumentRoot "$webDir"
    <Directory "$webDir">
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
"@
            }
            $lineas += ($vhost -split "`n")
            Set-Content $conf $lineas -Encoding ASCII
            $test = & "$rutaApache\bin\httpd.exe" -t 2>&1
            if ($test -match "Syntax OK") {
                Write-Host "Sintaxis Apache correcta." -ForegroundColor Green
                Crear-Pagina "apache" $P
                Restart-Service Apache* -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
            } else {
                Write-Host "Error en config de Apache:" -ForegroundColor Red
                $test | Out-String | Write-Host -ForegroundColor Red
                Pause; return
            }
        }

        "iis" {
            Write-Host "Configurando IIS en puerto $P..." -ForegroundColor Cyan
            Import-Module WebAdministration
            Get-Website | Stop-Website -ErrorAction SilentlyContinue
            Remove-Website -Name "Default Web Site" -ErrorAction SilentlyContinue
            Remove-Website -Name "SitioP7" -ErrorAction SilentlyContinue
            $webRoot = "C:\inetpub\wwwroot"
            New-Website -Name "SitioP7" -Port $P -PhysicalPath $webRoot -Force
            if ($usarSSL) {
                $certObj = Obtener-CertObj
                if ($certObj) {
                    Get-ChildItem -Path "IIS:\SslBindings" | Where-Object { $_.Port -eq $P } | Remove-Item -Force -ErrorAction SilentlyContinue
                    New-WebBinding -Name "SitioP7" -IPAddress "*" -Port $P -Protocol "https"
                    $certObj | New-Item -Path "IIS:\SslBindings\*!$P" -Force
                    Write-Host "SSL vinculado al puerto $P" -ForegroundColor Green
                }
            }
            New-NetFirewallRule -DisplayName "IIS_Port_$P" -Direction Inbound -LocalPort $P -Protocol TCP -Action Allow -ErrorAction SilentlyContinue
            Restart-Service W3SVC -Force
            Write-Host "Esperando que IIS levante..."
            Start-Sleep -Seconds 5
        }
    }

    Start-Sleep -Seconds 2
    if (Get-NetTCPConnection -LocalPort $P -State Listen -ErrorAction SilentlyContinue) {
        Write-Host "$Servicio activo en puerto $P" -ForegroundColor Green
        Write-Host "Acceso: ${protocolo}://192.168.1.235:$P" -ForegroundColor Cyan
    } else {
        Write-Host "$Servicio no levanto en puerto $P" -ForegroundColor Red
    }
    Pause
}

function Listar-Archivos-FTP {
    param($url, $usuario, $clave)
    try {
        $req = [System.Net.FtpWebRequest]::Create($url)
        $req.Method = [System.Net.WebRequestMethods+Ftp]::ListDirectoryDetails
        $req.Credentials = New-Object System.Net.NetworkCredential($usuario, $clave)
        $req.UsePassive = $true; $req.UseBinary = $true; $req.KeepAlive = $false
        $resp   = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $lista  = $reader.ReadToEnd(); $reader.Close(); $resp.Close()
        $archivos = @()
        foreach ($linea in ($lista -split "`n")) {
            $l = $linea.Trim().TrimEnd("`r")
            if ($l -eq "") { continue }
            $tokens = ($l -split " +") | Where-Object { $_ -ne "" }
            if ($tokens.Count -ge 4) {
                $nombre = $tokens[-1]
                if ($nombre -notlike "*.sha256" -and $nombre -ne "") { $archivos += $nombre }
            }
        }
        return $archivos
    } catch {
        Write-Host "Error FTP: $($_.Exception.Message)" -ForegroundColor Red
        return @()
    }
}

function Descargar-FTP {
    param($url, $destino, $usuario, $clave)
    try {
        $req = [System.Net.FtpWebRequest]::Create($url)
        $req.Method = [System.Net.WebRequestMethods+Ftp]::DownloadFile
        $req.Credentials = New-Object System.Net.NetworkCredential($usuario, $clave)
        $req.UsePassive = $true; $req.UseBinary = $true; $req.KeepAlive = $false
        $resp = $req.GetResponse()
        $fs   = [System.IO.File]::Create($destino)
        $resp.GetResponseStream().CopyTo($fs); $fs.Close(); $resp.Close()
        return $true
    } catch {
        Write-Host "Error descargando: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Instalar-Servicio {
    param($Servicio)
    $ServicioFTP = switch ($Servicio.ToLower()) {
        "nginx"  { "Nginx" }
        "apache" { "Apache" }
        "iis"    { "IIS" }
        default  { $Servicio }
    }
    $paquete = switch ($Servicio.ToLower()) {
        "nginx"  { "nginx" }
        "apache" { "apache-httpd" }
        "iis"    { "iis" }
    }
    Write-Host ""
    Write-Host "Instalando: $Servicio" -ForegroundColor Cyan
    Write-Host "1) Chocolatey (Oficial)  2) FTP ($global:FTP_IP)"
    $origen = Read-Host "Origen"

    if ($origen -eq "1") {
        if ($Servicio -eq "iis") {
            Install-WindowsFeature -Name Web-Server -IncludeManagementTools
            Install-WindowsFeature -Name Web-Http-Redirect -ErrorAction SilentlyContinue
            Write-Host "IIS instalado." -ForegroundColor Green
            Pause
            $dep = Read-Host "Desplegar IIS en puerto $global:PUERTO_ACTUAL? [S/N]"
            if ($dep -match '^[Ss]$') { Aplicar-Despliegue "iis" }
            return
        }
        $chocoExe = Garantizar-Chocolatey
        Limpiar-Entorno 80
        Write-Host "Consultando versiones para $paquete..." -ForegroundColor Cyan
        $raw  = & $chocoExe search $paquete --exact --limit-output 2>$null
        $vers = @($raw | Where-Object { $_ -match '^\S+\|\d' })
        if ($vers.Count -eq 0) {
            Write-Host "Instalando..." -ForegroundColor Cyan
            & $chocoExe install $paquete -y | Out-Null
        } else {
            Write-Host "Versiones disponibles:"
            for ($i=0; $i -lt $vers.Count; $i++) { $p=$vers[$i].Split('|'); Write-Host "$($i+1)) $($p[0]) v$($p[1])" }
            $sel = Read-Host "Selecciona (Enter = ultima)"
            Write-Host "Instalando..." -ForegroundColor Cyan
            if ([string]::IsNullOrWhiteSpace($sel)) {
                & $chocoExe install $paquete -y | Out-Null
            } else {
                $si = 0
                if ([int]::TryParse($sel,[ref]$si) -and $si -ge 1 -and $si -le $vers.Count) {
                    $v = $vers[$si-1].Split('|')[1].Trim()
                    & $chocoExe install $paquete --version $v -y | Out-Null
                } else { & $chocoExe install $paquete -y | Out-Null }
            }
        }
        Write-Host "Instalacion completada." -ForegroundColor Green
    } else {
        $ftpDir  = "$global:FTP_BASE/$ServicioFTP"
        Write-Host "Listando $ftpDir ..." -ForegroundColor Cyan
        $archivos = Listar-Archivos-FTP $ftpDir $global:FTP_USER $global:FTP_PASS
        if ($archivos.Count -eq 0) { Pause; return }
        for ($i=0; $i -lt $archivos.Count; $i++) { Write-Host "$($i+1)) $($archivos[$i])" }
        $idx = 0; $sel = Read-Host "Seleccione"
        if (![int]::TryParse($sel,[ref]$idx) -or $idx -lt 1 -or $idx -gt $archivos.Count) { Write-Host "Seleccion invalida." -ForegroundColor Red; Pause; return }
        $archivo   = $archivos[$idx-1]
        $destLocal = Join-Path $env:TEMP $archivo
        Write-Host "Descargando $archivo..." -ForegroundColor Cyan
        if (!(Descargar-FTP "$ftpDir/$archivo" $destLocal $global:FTP_USER $global:FTP_PASS)) { Pause; return }
        $ok2 = Descargar-FTP "$ftpDir/$archivo.sha256" "$destLocal.sha256" $global:FTP_USER $global:FTP_PASS
        if ($ok2 -and (Test-Path "$destLocal.sha256")) {
            $h1 = (Get-FileHash $destLocal -Algorithm SHA256).Hash.ToUpper()
            $h2 = (Get-Content "$destLocal.sha256").Trim().Split()[0].ToUpper()
            if ($h1 -ne $h2) { Write-Host "Hash invalido." -ForegroundColor Red; Pause; return }
            Write-Host "Hash verificado." -ForegroundColor Green
        }
        if ($archivo -like "*.zip") {
            $dest = "C:\tools\$Servicio"
            if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
            Expand-Archive -Path $destLocal -DestinationPath $dest -Force
            Write-Host "Extraido en $dest" -ForegroundColor Green
        } elseif ($archivo -like "*.msi") {
            Start-Process msiexec.exe -ArgumentList "/i `"$destLocal`" /quiet" -Wait
        }
    }
    $dep = Read-Host "Desplegar ahora en puerto $global:PUERTO_ACTUAL? [S/N]"
    if ($dep -match '^[Ss]$') { Aplicar-Despliegue $Servicio }
}

function Configurar-FTP-Seguro {
    $appcmd = "$env:windir\system32\inetsrv\appcmd.exe"
    $sitioFTP = & $appcmd list site 2>$null |
        ForEach-Object { if ($_ -match 'SITE object "([^"]+)"') { $matches[1] } } |
        Where-Object { $_ -ne "" } | Select-Object -First 1
    if (!$sitioFTP) {
        if (!(Test-Path "C:\FTP_Publico")) { New-Item "C:\FTP_Publico" -ItemType Directory -Force | Out-Null }
        & $appcmd add site /name:"ServidorFTP" /bindings:"ftp/*:21:" /physicalPath:"C:\FTP_Publico" 2>$null
        $sitioFTP = "ServidorFTP"
    }
    Write-Host "Sitio FTP detectado: $sitioFTP" -ForegroundColor Cyan
    $certObj = Obtener-CertObj
    & $appcmd set site "$sitioFTP" "-ftpServer.security.ssl.controlChannelPolicy:SslAllow" 2>$null
    & $appcmd set site "$sitioFTP" "-ftpServer.security.ssl.dataChannelPolicy:SslAllow" 2>$null
    & $appcmd set site "$sitioFTP" "-ftpServer.security.ssl.serverCertHash:$($certObj.Thumbprint)" 2>$null
    & $appcmd set config "$sitioFTP" /section:system.ftpServer/security/authentication/anonymousAuthentication /enabled:true /commit:apphost 2>$null
    & $appcmd set config "$sitioFTP" /section:system.ftpServer/security/authentication/basicAuthentication /enabled:true /commit:apphost 2>$null
    Set-Service ftpsvc -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service ftpsvc -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    & $appcmd start site "$sitioFTP" 2>$null
    Start-Sleep -Seconds 2
    if (Get-NetTCPConnection -LocalPort 21 -State Listen -ErrorAction SilentlyContinue) {
        Write-Host "FTP activo en puerto 21 - Sitio: $sitioFTP" -ForegroundColor Green
    } else {
        Restart-Service ftpsvc -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        & $appcmd start site "$sitioFTP" 2>$null
        Start-Sleep -Seconds 2
        if (Get-NetTCPConnection -LocalPort 21 -State Listen -ErrorAction SilentlyContinue) {
            Write-Host "FTP activo." -ForegroundColor Green
        } else {
            Write-Host "FTP no levanto. Ejecuta: net start ftpsvc" -ForegroundColor Red
        }
    }
    Pause
}

function Validar-Puerto-Seguro {
    while ($true) {
        $nuevo = Read-Host "Puerto (recomendado: 8080, 8443, 9090)"
        if (-not ($nuevo -match '^\d+$') -or [int]$nuevo -lt 1 -or [int]$nuevo -gt 65535) {
            Write-Host "Puerto invalido." -ForegroundColor Red; continue
        }
        if ([int]$nuevo -in $PUERTOS_BLOQUEADOS) {
            Write-Host "Puerto $nuevo bloqueado por navegadores." -ForegroundColor Red
            $c = Read-Host "Usar de todas formas? [S/N]"
            if ($c -notmatch '^[Ss]$') { continue }
        }
        $global:PUERTO_ACTUAL = $nuevo
        Write-Host "Puerto $nuevo asignado." -ForegroundColor Green
        return
    }
}

function Mostrar-Resumen {
    $p = if ($global:PUERTO_ACTUAL -and $global:PUERTO_ACTUAL -ne "N/A") { [int]$global:PUERTO_ACTUAL } else { 0 }
    $servicios = @(
        @{ Nombre = "Nginx (HTTP)";   Puerto = $p;  Protocolo = "http"  }
        @{ Nombre = "Nginx (HTTPS)";  Puerto = $p;  Protocolo = "https" }
        @{ Nombre = "Apache (HTTP)";  Puerto = $p;  Protocolo = "http"  }
        @{ Nombre = "Apache (HTTPS)"; Puerto = $p;  Protocolo = "https" }
        @{ Nombre = "IIS (HTTP)";     Puerto = 80;  Protocolo = "http"  }
        @{ Nombre = "IIS (HTTPS)";    Puerto = $p;  Protocolo = "https" }
        @{ Nombre = "IIS-FTP";        Puerto = 21;  Protocolo = "ftp"   }
        @{ Nombre = "Redireccion 80"; Puerto = 80;  Protocolo = "http"  }
    )
    Write-Host ""
    Write-Host "========= RESUMEN DE INFRAESTRUCTURA - $(Get-Date -Format 'dd/MM/yyyy HH:mm') =========" -ForegroundColor Cyan
    Write-Host ("{0,-25} {1,-8} {2,-10} {3}" -f "Servicio", "Puerto", "Estado", "Detalle")
    Write-Host ("-" * 62)
    $activos = 0; $total = 0
    foreach ($svc in $servicios) {
        if ($svc.Puerto -eq 0) {
            Write-Host ("{0,-25} {1,-8} {2,-10} {3}" -f $svc.Nombre, "N/A", "SKIP", "Puerto no configurado")
            continue
        }
        $total++
        $escuchando = Get-NetTCPConnection -LocalPort $svc.Puerto -State Listen -ErrorAction SilentlyContinue
        if ($escuchando) {
            $activos++
            $sslOk = $false; $sslDetalle = ""
            if ($svc.Protocolo -eq "https") {
                try {
                    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
                    $req = [System.Net.HttpWebRequest]::Create("https://localhost:$($svc.Puerto)")
                    $req.Timeout = 4000
                    $resp = $req.GetResponse()
                    $sslOk = $true; $sslDetalle = "SSL OK"
                    $resp.Close()
                } catch { $sslDetalle = "SSL ERROR" }
                [Net.ServicePointManager]::ServerCertificateValidationCallback = $null
            }
            $certInfo = ""
            if ($svc.Protocolo -eq "https") {
                $certObj = Get-ChildItem "Cert:\LocalMachine\My" | Where-Object { $_.Subject -like "*reprobados*" } | Select-Object -First 1
                if ($certObj) {
                    $dias = ($certObj.NotAfter - (Get-Date)).Days
                    $certInfo = "Cert: reprobados.com (vence en $dias dias)"
                } else { $certInfo = "Cert: NO ENCONTRADO" }
            }
            $detalle = if ($svc.Protocolo -eq "https") { "$sslDetalle | $certInfo" } else { "Escuchando" }
            $color   = if ($svc.Protocolo -eq "https" -and !$sslOk) { "Cyan" } else { "Green" }
            Write-Host ("{0,-25} {1,-8} {2,-10} {3}" -f $svc.Nombre, $svc.Puerto, "[ACTIVO]", $detalle) -ForegroundColor $color
        } else {
            Write-Host ("{0,-25} {1,-8} {2,-10} {3}" -f $svc.Nombre, $svc.Puerto, "[INACTIVO]", "No escucha en este puerto") -ForegroundColor Red
        }
    }
    Write-Host ("-" * 62)
    Write-Host "Servicios activos: $activos / $total" -ForegroundColor $(if ($activos -eq $total) { "Green" } else { "Cyan" })
    Write-Host ""
    Write-Host "Certificado SSL en almacen Windows:" -ForegroundColor Cyan
    $certObj = Get-ChildItem "Cert:\LocalMachine\My" | Where-Object { $_.Subject -like "*reprobados*" } | Select-Object -First 1
    if ($certObj) {
        Write-Host "  Subject   : $($certObj.Subject)" -ForegroundColor Green
        Write-Host "  Emitido   : $($certObj.NotBefore.ToString('dd/MM/yyyy'))" -ForegroundColor Green
        Write-Host "  Vence     : $($certObj.NotAfter.ToString('dd/MM/yyyy'))" -ForegroundColor Green
        Write-Host "  Thumbprint: $($certObj.Thumbprint)" -ForegroundColor Green
    } else {
        Write-Host "  Certificado reprobados.com NO encontrado en el almacen." -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "Archivos SSL en disco:" -ForegroundColor Cyan
    foreach ($f in @("C:\ssl\reprobados\reprobados.crt","C:\ssl\reprobados\reprobados.key")) {
        if (Test-Path $f) { Write-Host "  Existe: $f" -ForegroundColor Green }
        else { Write-Host "  No encontrado: $f" -ForegroundColor Red }
    }
    Write-Host "=============================================================" -ForegroundColor Cyan
    Pause
}

function Asegurar-FTP-Activo {
    $ftpActivo = Get-NetTCPConnection -LocalPort 21 -State Listen -ErrorAction SilentlyContinue
    if (!$ftpActivo) {
        Write-Host "Arrancando servicio FTP..." -ForegroundColor Cyan
        Set-Service ftpsvc -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service ftpsvc -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        $appcmd = "$env:windir\system32\inetsrv\appcmd.exe"
        & $appcmd list site 2>$null |
            ForEach-Object { if ($_ -match 'SITE object "([^"]+)"') { $matches[1] } } |
            Where-Object { $_ -ne "" } |
            ForEach-Object { & $appcmd start site "$_" 2>$null }
        Start-Sleep -Seconds 2
        if (Get-NetTCPConnection -LocalPort 21 -State Listen -ErrorAction SilentlyContinue) {
            Write-Host "FTP activo en puerto 21." -ForegroundColor Green
        } else {
            Write-Host "FTP no pudo arrancar." -ForegroundColor Red
        }
    }
}

function Menu-FTP-HTTP {
    $global:FTP_IP   = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" -and $_.IPAddress -notlike "169.*" } | Select-Object -First 1).IPAddress
    $global:FTP_USER = "anonymous"
    $global:FTP_PASS = ""
    $global:FTP_BASE = "ftp://127.0.0.1/http/Windows"

    Asegurar-FTP-Activo

    while ($true) {
        $p = if ($global:PUERTO_ACTUAL -and $global:PUERTO_ACTUAL -ne "N/A") { $global:PUERTO_ACTUAL } else { "N/A" }
        Write-Host ""
        Write-Host "========= MODULO HTTP/FTP =========" -ForegroundColor Cyan
        Write-Host "IP    : $global:FTP_IP"
        Write-Host "Puerto: $p"
        Write-Host "==================================="
        Write-Host "1) Instalar + Desplegar Nginx"
        Write-Host "2) Instalar + Desplegar Apache"
        Write-Host "3) Instalar + Desplegar IIS"
        Write-Host "4) Configurar FTP Seguro (TLS)"
        Write-Host "5) Configurar Puerto"
        Write-Host "6) Verificar Netstat"
        Write-Host "7) Resumen de infraestructura"
        Write-Host "8) Volver al Orquestador"
        Write-Host "==================================="
        $opcion = Read-Host "Opcion"

        switch ($opcion) {
            "1" { Instalar-Servicio "nginx"  }
            "2" { Instalar-Servicio "apache" }
            "3" { Instalar-Servicio "iis"    }
            "4" { Configurar-FTP-Seguro }
            "5" { Validar-Puerto-Seguro }
            "6" {
                Write-Host ""
                Write-Host "Puertos activos:" -ForegroundColor Cyan
                $puertos = @(80,443,21,8080,8443,9090)
                if ($p -match '^\d+$') { $puertos += [int]$p }
                Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                    Where-Object { $_.LocalPort -in $puertos } |
                    Select-Object LocalAddress, LocalPort | Sort-Object LocalPort | Format-Table -AutoSize
                Pause
            }
            "7" { Mostrar-Resumen }
            "8" { return }
            default { Write-Host "Opcion invalida." -ForegroundColor Red }
        }
    }
}

Menu-FTP-HTTP
