# Servicio FTP - Windows

# --- Rutas base ---
$RAIZ_FTP        = "C:\FTP"
$RAIZ_USUARIOS   = "$RAIZ_FTP\LocalUser"
$RAIZ_GRUPOS     = "$RAIZ_FTP\grupos"
$CARPETA_GENERAL = "$RAIZ_USUARIOS\Public\general"
$SITIO_FTP       = "ServidorFTP"
$PUERTO_FTP      = 21
$ARCHIVO_LOG     = "$RAIZ_FTP\logs\gestion_ftp.log"

#=============== FUNCIONES ====================

function Registrar {
    param(
        [string]$Mensaje,
        [string]$Tipo = "INFO"
    )
    $fecha = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $linea = "[$fecha] [$Tipo] $Mensaje"
    $logDir = Split-Path $ARCHIVO_LOG
    if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $ARCHIVO_LOG -Value $linea
    switch ($Tipo) {
        "OK"    { Write-Host $linea -ForegroundColor Green }
        "ERROR" { Write-Host $linea -ForegroundColor Red }
        default { Write-Host $linea }
    }
}

function Verificar-Admin {
    $identidad = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identidad)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "[ERROR] Debes ejecutar este script como Administrador." -ForegroundColor Red
        exit 1
    }
}

function Validar-Contrasena {
    param([string]$Contrasena)
    $longitud = $Contrasena.Length
    if ($longitud -lt 8 -or $longitud -gt 15) { return $false }
    if ($Contrasena -notmatch '[A-Z]')         { return $false }
    if ($Contrasena -notmatch '[a-z]')         { return $false }
    if ($Contrasena -notmatch '[0-9]')         { return $false }
    if ($Contrasena -notmatch '[^a-zA-Z0-9]') { return $false }
    return $true
}

function Asignar-Permiso {
    param(
        [string]$Ruta,
        [string]$Usuario,
        [string]$Permiso = "Modify"
    )
    try {
        $acl = Get-Acl $Ruta
        $regla = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $Usuario, $Permiso, "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $acl.SetAccessRule($regla)
        Set-Acl -Path $Ruta -AclObject $acl
    } catch {
        Registrar "Advertencia al asignar permiso en '$Ruta' para '$Usuario'." "INFO"
    }
}

function Quitar-Permiso {
    param(
        [string]$Ruta,
        [string]$Usuario
    )
    if (!(Test-Path $Ruta)) { return }
    try {
        $acl = Get-Acl $Ruta
        $acl.Access | Where-Object { $_.IdentityReference -like "*\$Usuario" } | ForEach-Object {
            $acl.RemoveAccessRule($_) | Out-Null
        }
        Set-Acl -Path $Ruta -AclObject $acl
    } catch {
        Registrar "Advertencia al quitar permiso en '$Ruta' para '$Usuario'." "INFO"
    }
}

function Instalar-Entorno {
    Registrar "Verificando instalacion de IIS y FTP..." "INFO"

    $caracteristicas = @("Web-Server", "Web-Ftp-Server", "Web-Ftp-Service")
    foreach ($caracteristica in $caracteristicas) {
        $estado = Get-WindowsFeature -Name $caracteristica
        if (-not $estado.Installed) {
            Install-WindowsFeature -Name $caracteristica -IncludeManagementTools | Out-Null
            Registrar "Caracteristica '$caracteristica' instalada." "OK"
        } else {
            Registrar "Caracteristica '$caracteristica' ya estaba instalada." "INFO"
        }
    }

    Import-Module WebAdministration -ErrorAction SilentlyContinue

    $directorios = @(
        $CARPETA_GENERAL,
        "$RAIZ_GRUPOS\reprobados",
        "$RAIZ_GRUPOS\recursadores",
        "$RAIZ_FTP\logs"
    )
    foreach ($dir in $directorios) {
        if (!(Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Registrar "Directorio creado: $dir" "INFO"
        }
    }

    foreach ($grupo in @("reprobados", "recursadores")) {
        if (!(Get-LocalGroup -Name $grupo -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $grupo -Description "Grupo FTP $grupo"
            Registrar "Grupo local '$grupo' creado." "OK"
        }
    }

    # Usuario anonimo local para acceso publico de solo lectura
    if (!(Get-LocalUser -Name "ftp_anonymous" -ErrorAction SilentlyContinue)) {
        $anonPass = ConvertTo-SecureString "Anon@FTP2024!" -AsPlainText -Force
        New-LocalUser -Name "ftp_anonymous" -Password $anonPass -PasswordNeverExpires | Out-Null
        Registrar "Usuario 'ftp_anonymous' creado." "OK"
    }

    # Permisos carpeta general: ftp_anonymous solo lectura
    Asignar-Permiso -Ruta $CARPETA_GENERAL -Usuario "ftp_anonymous" -Permiso "ReadAndExecute"

    if (!(Get-WebSite -Name $SITIO_FTP -ErrorAction SilentlyContinue)) {
        New-WebFtpSite -Name $SITIO_FTP -Port $PUERTO_FTP -PhysicalPath $RAIZ_USUARIOS -Force | Out-Null
        Registrar "Sitio FTP '$SITIO_FTP' creado en puerto $PUERTO_FTP." "OK"
    }

    # Aislamiento por directorio de usuario
    Set-ItemProperty "IIS:\Sites\$SITIO_FTP" -Name ftpServer.userIsolation.mode -Value "IsolateDirectory"

    $appcmd = "$env:windir\system32\inetsrv\appcmd.exe"

    # Desbloquear secciones FTP
    & $appcmd unlock config -section:system.ftpServer/security/authentication/anonymousAuthentication | Out-Null
    & $appcmd unlock config -section:system.ftpServer/security/authentication/basicAuthentication     | Out-Null
    & $appcmd unlock config -section:system.ftpServer/security/authorization                          | Out-Null

    # Configurar autenticacion
    & $appcmd set config "$SITIO_FTP" -section:system.ftpServer/security/authentication/anonymousAuthentication /enabled:true /userName:ftp_anonymous /commit:apphost | Out-Null
    & $appcmd set config "$SITIO_FTP" -section:system.ftpServer/security/authentication/basicAuthentication /enabled:true /commit:apphost | Out-Null

    # Reglas de autorizacion: anonimo solo lectura, autenticados lectura y escritura
    & $appcmd clear config "$SITIO_FTP" -section:system.ftpServer/security/authorization /commit:apphost | Out-Null
    & $appcmd set config "$SITIO_FTP" -section:system.ftpServer/security/authorization /+"[accessType='Allow',users='?',permissions='Read']" /commit:apphost | Out-Null
    & $appcmd set config "$SITIO_FTP" -section:system.ftpServer/security/authorization /+"[accessType='Allow',users='*',permissions='Read,Write']" /commit:apphost | Out-Null

    # Deshabilitar SSL
    Set-ItemProperty "IIS:\Sites\$SITIO_FTP" -Name ftpServer.security.ssl.controlChannelPolicy -Value 0
    Set-ItemProperty "IIS:\Sites\$SITIO_FTP" -Name ftpServer.security.ssl.dataChannelPolicy -Value 0

    $reglaFirewall = Get-NetFirewallRule -DisplayName "FTP Puerto 21" -ErrorAction SilentlyContinue
    if (-not $reglaFirewall) {
        New-NetFirewallRule -DisplayName "FTP Puerto 21" -Direction Inbound -Protocol TCP -LocalPort 21 -Action Allow | Out-Null
        Registrar "Puerto 21 habilitado en firewall de Windows." "OK"
    }

    Restart-Service ftpsvc -Force
    Registrar "Entorno FTP listo y servicio activo." "OK"
}

function Crear-Usuario {
    param(
        [string]$Usuario,
        [string]$Contrasena,
        [string]$Grupo
    )

    $pass = ConvertTo-SecureString $Contrasena -AsPlainText -Force
    New-LocalUser -Name $Usuario -Password $pass -PasswordNeverExpires | Out-Null
    Add-LocalGroupMember -Group $Grupo -Member $Usuario
    Registrar "Usuario '$Usuario' creado y agregado al grupo '$Grupo'." "OK"

    # IIS FTP con IsolateDirectory busca: \LocalUser\<usuario>\<usuario>
    $raiz_chroot = "$RAIZ_USUARIOS\$Usuario"
    New-Item -ItemType Directory -Path "$raiz_chroot\$Usuario" -Force | Out-Null

    # Permisos carpeta personal
    Asignar-Permiso -Ruta "$raiz_chroot\$Usuario" -Usuario $Usuario

    # Permisos en general y grupo
    Asignar-Permiso -Ruta $CARPETA_GENERAL -Usuario $Usuario
    Asignar-Permiso -Ruta "$RAIZ_GRUPOS\$Grupo" -Usuario $Usuario

    # Enlaces simbolicos /D (no junctions) para que IIS FTP los reconozca
    cmd /c "mklink /D `"$raiz_chroot\general`" `"$CARPETA_GENERAL`"" | Out-Null
    cmd /c "mklink /D `"$raiz_chroot\$Grupo`" `"$RAIZ_GRUPOS\$Grupo`"" | Out-Null

    Registrar "Estructura de directorios y permisos asignados a '$Usuario'." "OK"
}

function Alta-Usuario {
    Write-Host ""
    Write-Host "-- Alta de usuario FTP --"

    $usuario = Read-Host "Nombre de usuario"
    $usuario = $usuario.Trim()

    if ([string]::IsNullOrEmpty($usuario)) {
        Registrar "El nombre de usuario no puede estar vacio." "ERROR"
        return
    }
    if (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue) {
        Registrar "El usuario '$usuario' ya existe en el sistema." "ERROR"
        return
    }

    $contrasena = Read-Host "Contrasena (8-15 chars, mayuscula, minuscula, numero, especial)" -AsSecureString
    $contrasenaPlana = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($contrasena)
    )
    if (!(Validar-Contrasena -Contrasena $contrasenaPlana)) {
        Registrar "La contrasena no cumple los requisitos de seguridad." "ERROR"
        return
    }

    Write-Host "Grupos disponibles:"
    Write-Host "  1) reprobados"
    Write-Host "  2) recursadores"
    $opcion = Read-Host "Selecciona el grupo del usuario"

    switch ($opcion) {
        "1" { $grupo = "reprobados" }
        "2" { $grupo = "recursadores" }
        default {
            Registrar "Opcion de grupo no valida." "ERROR"
            return
        }
    }

    Crear-Usuario -Usuario $usuario -Contrasena $contrasenaPlana -Grupo $grupo
}

function Alta-Masiva {
    Write-Host ""
    Write-Host "-- Alta masiva de usuarios FTP --"

    $cantidad = Read-Host "Cuantos usuarios deseas registrar?"
    if ($cantidad -notmatch '^\d+$' -or [int]$cantidad -le 0) {
        Registrar "Cantidad invalida. Ingresa un numero entero positivo." "ERROR"
        return
    }

    $creados  = 0
    $omitidos = 0

    for ($i = 1; $i -le [int]$cantidad; $i++) {
        Write-Host ""
        Write-Host "-- Usuario $i de $cantidad --"

        $usuario = (Read-Host "  Nombre de usuario").Trim()
        if ([string]::IsNullOrEmpty($usuario)) {
            Registrar "Nombre vacio, se omite el usuario $i." "ERROR"
            $omitidos++
            continue
        }
        if (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue) {
            Registrar "El usuario '$usuario' ya existe, se omite." "ERROR"
            $omitidos++
            continue
        }

        $contrasena = Read-Host "  Contrasena" -AsSecureString
        $contrasenaPlana = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($contrasena)
        )
        if (!(Validar-Contrasena -Contrasena $contrasenaPlana)) {
            Registrar "Contrasena invalida para '$usuario', se omite." "ERROR"
            $omitidos++
            continue
        }

        Write-Host "  Grupos: 1) reprobados   2) recursadores"
        $opcion = Read-Host "  Grupo"

        switch ($opcion) {
            "1" { $grupo = "reprobados" }
            "2" { $grupo = "recursadores" }
            default {
                Registrar "Grupo invalido para '$usuario', se omite." "ERROR"
                $omitidos++
                continue
            }
        }

        Crear-Usuario -Usuario $usuario -Contrasena $contrasenaPlana -Grupo $grupo
        $creados++
    }

    Write-Host ""
    Registrar "Alta masiva completada. Creados: $creados | Omitidos: $omitidos." "OK"
}

function Cambiar-Grupo {
    Write-Host ""
    Write-Host "-- Cambio de grupo --"

    $usuario = (Read-Host "Nombre de usuario").Trim()
    if (!(Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue)) {
        Registrar "El usuario '$usuario' no existe." "ERROR"
        return
    }

    $grupo_actual = $null
    foreach ($g in @("reprobados", "recursadores")) {
        $miembros = Get-LocalGroupMember -Group $g -ErrorAction SilentlyContinue
        if ($miembros | Where-Object { $_.Name -like "*\$usuario" }) {
            $grupo_actual = $g
            break
        }
    }

    if ($null -eq $grupo_actual) {
        Registrar "El usuario '$usuario' no pertenece a ningun grupo FTP conocido." "ERROR"
        return
    }

    $grupo_nuevo = if ($grupo_actual -eq "reprobados") { "recursadores" } else { "reprobados" }

    Write-Host "El usuario '$usuario' pertenece actualmente a: $grupo_actual"
    $confirmacion = Read-Host "Moverlo a '$grupo_nuevo'? (s/N)"
    if ($confirmacion -notmatch '^[Ss]$') {
        Registrar "Cambio de grupo cancelado." "INFO"
        return
    }

    Remove-LocalGroupMember -Group $grupo_actual -Member $usuario
    Add-LocalGroupMember -Group $grupo_nuevo -Member $usuario

    $raiz_chroot = "$RAIZ_USUARIOS\$usuario"

    Quitar-Permiso -Ruta "$RAIZ_GRUPOS\$grupo_actual" -Usuario $usuario
    Asignar-Permiso -Ruta "$RAIZ_GRUPOS\$grupo_nuevo" -Usuario $usuario

    # Actualizar enlace simbolico de grupo
    $linkAntiguo = "$raiz_chroot\$grupo_actual"
    $linkNuevo   = "$raiz_chroot\$grupo_nuevo"
    if (Test-Path $linkAntiguo) { cmd /c "rmdir `"$linkAntiguo`"" | Out-Null }
    if (!(Test-Path $linkNuevo)) {
        cmd /c "mklink /D `"$linkNuevo`" `"$RAIZ_GRUPOS\$grupo_nuevo`"" | Out-Null
    }

    Registrar "Usuario '$usuario' movido de '$grupo_actual' a '$grupo_nuevo'." "OK"
}

function Eliminar-Usuario {
    Write-Host ""
    Write-Host "-- Eliminar usuario FTP --"

    $usuario = (Read-Host "Nombre de usuario a eliminar").Trim()
    if (!(Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue)) {
        Registrar "El usuario '$usuario' no existe en el sistema." "ERROR"
        return
    }

    Write-Host ""
    Write-Host "ADVERTENCIA: Esta accion elimina al usuario y todos sus archivos. No se puede deshacer." -ForegroundColor Red
    $confirmacion = Read-Host "Escribe el nombre del usuario para confirmar"

    if ($confirmacion -ne $usuario) {
        Registrar "Confirmacion incorrecta. No se realizo ningun cambio." "ERROR"
        return
    }

    Quitar-Permiso -Ruta $CARPETA_GENERAL -Usuario $usuario
    foreach ($g in @("reprobados", "recursadores")) {
        Quitar-Permiso -Ruta "$RAIZ_GRUPOS\$g" -Usuario $usuario
        Remove-LocalGroupMember -Group $g -Member $usuario -ErrorAction SilentlyContinue
    }

    Remove-LocalUser -Name $usuario

    $raiz_chroot = "$RAIZ_USUARIOS\$usuario"
    if (Test-Path $raiz_chroot) {
        # Eliminar enlaces simbolicos primero
        foreach ($link in @("general", "reprobados", "recursadores")) {
            $path = "$raiz_chroot\$link"
            if (Test-Path $path) { cmd /c "rmdir `"$path`"" | Out-Null }
        }
        Remove-Item -Recurse -Force $raiz_chroot
    }

    Registrar "Usuario '$usuario' eliminado correctamente." "OK"
}

function Listar-Usuarios {
    Write-Host ""
    Write-Host "-- Usuarios FTP registrados por grupo --"

    foreach ($grupo in @("reprobados", "recursadores")) {
        Write-Host ""
        Write-Host "Grupo: $grupo"
        $miembros = Get-LocalGroupMember -Group $grupo -ErrorAction SilentlyContinue
        if ($null -eq $miembros -or $miembros.Count -eq 0) {
            Write-Host "  (sin usuarios asignados)"
        } else {
            foreach ($m in $miembros) {
                $nombre = $m.Name -replace ".*\\", ""
                Write-Host "  -> $nombre"
            }
        }
    }
    Write-Host ""
}

# MENU

Verificar-Admin
Instalar-Entorno

while ($true) {
    Write-Host ""
    Write-Host "========================================="
    Write-Host "      ADMINISTRADOR FTP - WINDOWS        "
    Write-Host "========================================="
    Write-Host " 1. Registrar un usuario"
    Write-Host " 2. Registro masivo de usuarios"
    Write-Host " 3. Cambiar usuario de grupo"
    Write-Host " 4. Eliminar usuario"
    Write-Host " 5. Listar usuarios por grupo"
    Write-Host " 6. Reiniciar servicio FTP"
    Write-Host " 7. Salir"
    Write-Host "-----------------------------------------"
    $opcion = Read-Host " Opcion"

    switch ($opcion) {
        "1" { Alta-Usuario }
        "2" { Alta-Masiva }
        "3" { Cambiar-Grupo }
        "4" { Eliminar-Usuario }
        "5" { Listar-Usuarios }
        "6" {
            Restart-Service ftpsvc -Force
            Registrar "Servicio FTP reiniciado manualmente." "OK"
        }
        "7" {
            Registrar "Sesion terminada." "INFO"
            exit 0
        }
        default { Write-Host "Opcion no reconocida. Intenta de nuevo." }
    }
}
