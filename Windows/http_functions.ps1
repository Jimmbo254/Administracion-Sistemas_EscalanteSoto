# http_functions.ps1 — Funciones HTTP Windows Server

$VM_IP = "192.168.56.102"

$PUERTOS_RESERVADOS = @(20,21,22,23,25,53,110,143,445,3306,3389,5432)

function Solicitar-Puerto {
    param([string]$ServicioNombre)
    while ($true) {
        $input_p = Read-Host "Ingresa puerto para $ServicioNombre (ej. 8080, 81)"
        if ([string]::IsNullOrWhiteSpace($input_p)) { return 8080 }
        if ($input_p -notmatch '^\d+$') { Write-Host "[!] Solo numeros." -ForegroundColor Red; continue }
        $p = [int]$input_p
        if ($PUERTOS_RESERVADOS -contains $p) {
            Write-Host "[!] Puerto $p esta reservado por el sistema. Elige otro." -ForegroundColor Red
            continue
        }
        $ocupado = Test-NetConnection -ComputerName localhost -Port $p -WarningAction SilentlyContinue
        if ($ocupado.TcpTestSucceeded) {
            Write-Host "[!] El puerto $p ya esta en uso. Intenta con otro." -ForegroundColor Red
            continue
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
  <title>$Servicio - Puerto $Puerto</title>
  <style>
    body { font-family: Arial, sans-serif; background-color: #f4f4f9; color: #333; text-align: center; padding: 50px; }
    .container { background: white; padding: 30px; border-radius: 10px; box-shadow: 0px 0px 10px rgba(0,0,0,0.1); display: inline-block; }
    h1 { color: #0078D7; }
  </style>
</head>
<body>
  <div class="container">
      <h1>Servidor Activo</h1>
      <p><strong>Servidor:</strong> $Servicio</p>
      <p><strong>Version:</strong> $Version</p>
      <p><strong>Puerto:</strong> $Puerto</p>
      <p><strong>IP VirtualBox:</strong> $VM_IP</p>
      <p>URL: http://${VM_IP}:${Puerto}</p>
  </div>
</body>
</html>
"@
    [IO.File]::WriteAllText("$Ruta\index.html", $html)
}

function Configurar-Firewall {
    param([int]$Puerto, [string]$Nombre)
    $ruleName = "HTTP-$Nombre-$Puerto"
    Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $Puerto -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
}

function Instalar-IIS {
    $puerto = 80
    Write-Host "`n[*] Configurando servidor HTTP Nativo de Windows..." -ForegroundColor Cyan
    $webRoot = "C:\inetpub\wwwroot\mi_sitio"
    Crear-Index -Ruta $webRoot -Servicio "Windows HTTP Nativo" -Version "System.Net" -Puerto $puerto
    Configurar-Firewall -Puerto $puerto -Nombre "HTTP-Nativo"
    $codigoServidor = @"
try {
`$listener = New-Object System.Net.HttpListener
`$listener.Prefixes.Add('http://*:$puerto/')
`$listener.Start()
while (`$listener.IsListening) {
`$context = `$listener.GetContext()
`$response = `$context.Response
`$content = Get-Content -Path '$webRoot\index.html' -Raw
`$buffer = [System.Text.Encoding]::UTF8.GetBytes(`$content)
`$response.ContentLength64 = `$buffer.Length
`$response.OutputStream.Write(`$buffer, 0, `$buffer.Length)
`$response.Close()
}
} catch { exit }
"@
    Start-Process powershell.exe -ArgumentList "-WindowStyle Hidden -NoProfile -Command `"$codigoServidor`""
    Write-Host "[OK] Servidor Web Nativo activo en puerto $puerto." -ForegroundColor Green
    Write-Host "[>] Abre en tu Host: http://${VM_IP}" -ForegroundColor Yellow
}

function Desinstalar-IIS {
    Write-Host "`n[*] Desinstalando IIS..." -ForegroundColor Yellow
    Stop-Process -Name "powershell" -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -eq "" }
    Remove-NetFirewallRule -DisplayName "HTTP-HTTP-Nativo-80" -ErrorAction SilentlyContinue
    Write-Host "[-] Sitio HTTP Nativo apagado." -ForegroundColor Green
}

function Instalar-Opcional {
    param($Servicio)
    $paquete = if ($Servicio -eq "apache") { "apache-httpd" } else { "nginx" }
    $nombreArchivo = if ($Servicio -eq "apache") { "httpd.conf" } else { "nginx.conf" }

    Write-Host "`n[*] Preparando instalacion de $Servicio..." -ForegroundColor Yellow
    $ver = "Latest"
    $puerto = Solicitar-Puerto -ServicioNombre $Servicio

    Write-Host "[*] Instalando $Servicio ($ver) desde Chocolatey..." -ForegroundColor Cyan
    if ($Servicio -eq "nginx") {
        choco install $paquete -y --force --package-parameters "/port:$puerto" | Out-Null
    } else {
        choco install $paquete -y --force | Out-Null
    }

    Write-Host "[*] Dando tiempo al sistema para desempaquetar archivos..." -ForegroundColor Yellow
    Start-Sleep -Seconds 3

    $archivoConf = $null
    $rutasBusqueda = @("C:\tools", "C:\ProgramData\chocolatey\lib", "C:\nginx")
    foreach ($ruta in $rutasBusqueda) {
        if (Test-Path $ruta) {
            $resultado = Get-ChildItem -Path $ruta -Filter $nombreArchivo -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($resultado) { $archivoConf = $resultado; break }
        }
    }

    if ($Servicio -eq "nginx") {
        if ($archivoConf) {
            $conf = $archivoConf.FullName
            $nginxRoot = $archivoConf.Directory.Parent.FullName
            $htmlDir = Join-Path -Path $nginxRoot -ChildPath "html"
            Stop-Process -Name "nginx" -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            $textoConf = Get-Content $conf
            $textoConf = $textoConf -replace '(?m)^\s*listen\s+\d+\s*;', "        listen       $puerto;"
            $textoConf | Set-Content $conf
            Crear-Index -Ruta $htmlDir -Servicio "Nginx" -Version $ver -Puerto $puerto
            $exeNginx = Get-ChildItem -Path $nginxRoot -Filter "nginx.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($exeNginx) {
                Write-Host "[*] Arrancando Nginx en segundo plano..." -ForegroundColor Yellow
                Start-Process $exeNginx.FullName -WorkingDirectory $exeNginx.Directory.FullName -WindowStyle Hidden
            } else { Write-Host "[Error] No se encontro nginx.exe." -ForegroundColor Red; return }
        } else { Write-Host "[Error] No se encontro nginx.conf." -ForegroundColor Red; return }
    }

    if ($Servicio -eq "apache") {
        if ($archivoConf) {
            $conf = $archivoConf.FullName
            $apacheRoot = $archivoConf.Directory.Parent.FullName
            $apacheRootFormat = $apacheRoot -replace "\\", "/"
            $htdocs = Join-Path -Path $apacheRoot -ChildPath "htdocs"
            $textoConf = Get-Content $conf
            $textoConf = $textoConf -replace 'Define SRVROOT .*', "Define SRVROOT `"$apacheRootFormat`""
            $textoConf = $textoConf -replace '(?i)c:/Apache24', $apacheRootFormat
            $textoConf = $textoConf -replace '(?m)^Listen\s+\d+', "Listen $puerto"
            $textoConf = $textoConf -replace '(?m)^#?\s*ServerName.*', "ServerName localhost:$puerto"
            $textoConf | Set-Content $conf
            Crear-Index -Ruta $htdocs -Servicio "Apache" -Version $ver -Puerto $puerto
            $apacheExe = Get-ChildItem -Path $apacheRoot -Filter "httpd.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($apacheExe) {
                Write-Host "[*] Instalando y arrancando Apache como servicio..." -ForegroundColor Yellow
                & $apacheExe.FullName -k uninstall 2>$null
                Stop-Process -Name "httpd" -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                & $apacheExe.FullName -k install 2>$null
                Start-Sleep -Seconds 2
                net start Apache2.4
            } else { Write-Host "[Error] No se encontro httpd.exe." -ForegroundColor Red; return }
        } else { Write-Host "[Error] No se encontro httpd.conf." -ForegroundColor Red; return }
    }

    Configurar-Firewall -Puerto $puerto -Nombre $Servicio
    Write-Host "[OK] $Servicio instalado correctamente." -ForegroundColor Green
    Write-Host "[>] Abre en tu Host: http://${VM_IP}:${puerto}" -ForegroundColor Yellow
}

function Desinstalar-Opcional {
    param($Servicio)
    $paquete = if ($Servicio -eq "apache") { "apache-httpd" } else { "nginx" }
    Write-Host "`n[*] Desinstalando $Servicio..." -ForegroundColor Yellow
    if ($Servicio -eq "nginx") { Stop-Process -Name "nginx" -Force -ErrorAction SilentlyContinue }
    if ($Servicio -eq "apache") {
        net stop Apache2.4 2>$null
        $apacheExe = Get-ChildItem -Path "C:\tools" -Filter "httpd.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($apacheExe) { & $apacheExe.FullName -k uninstall 2>$null }
        Stop-Process -Name "httpd" -Force -ErrorAction SilentlyContinue
    }
    choco uninstall $paquete -y | Out-Null
    Get-NetFirewallRule -DisplayName "HTTP-$Servicio-*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Get-ChildItem -Path "C:\tools" -Filter "*$paquete*" -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    if ($Servicio -eq "apache") { Get-ChildItem -Path "C:\tools" -Filter "*apache24*" -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
    if ($Servicio -eq "nginx")  { Get-ChildItem -Path "C:\tools" -Filter "*nginx*"    -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host "[-] $Servicio desinstalado y carpetas limpias." -ForegroundColor Green
}
