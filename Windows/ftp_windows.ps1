# Servicio FTP - Windows

# --- Rutas base ---
$RAIZ_FTP       = "C:\inetpub\ftp"
$RAIZ_USUARIOS  = "$RAIZ_FTP\usuarios"
$RAIZ_GRUPOS    = "$RAIZ_FTP\grupos"
$CARPETA_GENERAL = "$RAIZ_FTP\general"
$CARPETA_ANONIMO = "$RAIZ_FTP\anonimo"
$SITIO_FTP      = "ServidorFTP"
$PUERTO_FTP     = 21
$ARCHIVO_LOG    = "C:\logs\gestion_ftp.log"

#=============== FUNCIONES ====================

function Registrar {
    param(
        [string]$Mensaje,
        [string]$Tipo = "INFO"
    )
    $fecha = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $linea = "[$fecha] [$Tipo] $Mensaje"

    # Crear carpeta de log si no existe
    if (!(Test-Path "C:\logs")) { New-Item -ItemType Directory -Path "C:\logs" | Out-Null }
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
    if ($longitud -lt 8 -or $longitud -gt 15)          { return $false }
    if ($Contrasena -notmatch '[A-Z]')                  { return $false }
    if ($Contrasena -notmatch '[a-z]')                  { return $false }
    if ($Contrasena -notmatch '[0-9]')                  { return $false }
    if ($Contrasena -notmatch '[^a-zA-Z0-9]')           { return $false }
    return $true
}

# Asigna permisos NTFS a una carpeta para un usuario o grupo
# Parametros: ruta, identidad (EQUIPO\usuario), tipo de acceso (FullControl, ReadAndExecute, etc), Allow/Deny
function Asignar-Permiso {
    param(
        [string]$Ruta,
        [string]$Identidad,
        [string]$Permiso,
        [string]$Tipo = "Allow"
    )
    $acl = Get-Acl $Ruta
    $regla = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Identidad, $Permiso, "ContainerInherit,ObjectInherit", "None", $Tipo
    )
    $acl.SetAccessRule($regla)
    Set-Acl -Path $Ruta -AclObject $acl
}

function Instalar-Entorno {
    Registrar "Verificando instalación de IIS y FTP..." "INFO"

    # Instalar IIS con FTP si no están instalados
    $caracteristicas = @("Web-Server", "Web-Ftp-Server", "Web-Ftp-Service")
    foreach ($caracteristica in $caracteristicas) {
        $estado = Get-WindowsFeature -Name $caracteristica
        if (-not $estado.Installed) {
            Install-WindowsFeature -Name $caracteristica -IncludeManagementTools | Out-Null
            Registrar "Característica '$caracteristica' instalada." "OK"
        } else {
            Registrar "Característica '$caracteristica' ya estaba instalada." "INFO"
        }
    }

    # Importar módulo WebAdministration para gestionar IIS
    Import-Module WebAdministration -ErrorAction SilentlyContinue

    # Crear estructura de directorios
    $directorios = @(
        $CARPETA_GENERAL,
        "$CARPETA_ANONIMO\general",
        $RAIZ_USUARIOS,
        "$RAIZ_GRUPOS\reprobados",
        "$RAIZ_GRUPOS\recursadores"
    )
    foreach ($dir in $directorios) {
        if (!(Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Registrar "Directorio creado: $dir" "INFO"
        }
    }

    # Crear grupos locales si no existen
    foreach ($grupo in @("reprobados", "recursadores")) {
        if (!(Get-LocalGroup -Name $grupo -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $grupo -Description "Grupo FTP $grupo"
            Registrar "Grupo local '$grupo' creado." "OK"
        }
    }

    # Permisos carpeta general: todos los usuarios autenticados leen y escriben
    Asignar-Permiso -Ruta $CARPETA_GENERAL -Identidad "BUILTIN\Users" -Permiso "ReadAndExecute"
    Asignar-Permiso -Ruta $CARPETA_ANONIMO -Identidad "BUILTIN\\IIS_IUSRS" -Permiso "ReadAndExecute"

    # Copiar junction (enlace) de general en anonimo si no existe
    $junctionPath = "$CARPETA_ANONIMO\general"
    if (!(Test-Path $junctionPath)) {
        cmd /c "mklink /J `"$junctionPath`" `"$CARPETA_GENERAL`"" | Out-Null
        Registrar "Junction de general en anonimo creado." "OK"
    }

    # Permisos carpetas de grupo
    foreach ($grupo in @("reprobados", "recursadores")) {
        Asignar-Permiso -Ruta "$RAIZ_GRUPOS\$grupo" -Identidad "$env:COMPUTERNAME\$grupo" -Permiso "Modify"
    }

    # Crear o reconfigurar sitio FTP en IIS
    if (Get-WebSite -Name $SITIO_FTP -ErrorAction SilentlyContinue) {
        Remove-WebSite -Name $SITIO_FTP
        Registrar "Sitio FTP anterior eliminado para reconfigurar." "INFO"
    }

    New-WebFtpSite -Name $SITIO_FTP -Port $PUERTO_FTP -PhysicalPath $RAIZ_FTP -Force | Out-Null
    Registrar "Sitio FTP '$SITIO_FTP' creado en puerto $PUERTO_FTP." "OK"

    # Configurar acceso anónimo (solo lectura en /anonimo)
    Set-ItemProperty "IIS:\Sites\$SITIO_FTP" -Name ftpServer.security.authentication.anonymousAuthentication.enabled -Value $true
    Set-ItemProperty "IIS:\Sites\$SITIO_FTP" -Name ftpServer.security.authentication.basicAuthentication.enabled -Value $true

    # Regla de autorización: anónimo solo lectura
    Add-WebConfiguration "/system.ftpServer/security/authorization" -Value @{
        accessType  = "Allow"
        users       = ""
        roles       = ""
        permissions = "Read"
    } -PSPath "IIS:\" -Location "$SITIO_FTP"

    # Regla de autorización: usuarios autenticados lectura y escritura
    Add-WebConfiguration "/system.ftpServer/security/authorization" -Value @{
        accessType  = "Allow"
        users       = "*"
        roles       = ""
        permissions = "Read,Write"
    } -PSPath "IIS:\" -Location "$SITIO_FTP"

    # Habilitar aislamiento de usuarios (chroot)
    Set-ItemProperty "IIS:\Sites\$SITIO_FTP" -Name ftpServer.userIsolation.mode -Value "IsolateAllDirectories"

    # Abrir puerto 21 en el firewall de Windows
    $reglaFirewall = Get-NetFirewallRule -DisplayName "FTP Puerto 21" -ErrorAction SilentlyContinue
    if (-not $reglaFirewall) {
        New-NetFirewallRule -DisplayName "FTP Puerto 21" -Direction Inbound -Protocol TCP -LocalPort 21 -Action Allow | Out-Null
        Registrar "Puerto 21 habilitado en firewall de Windows." "OK"
    }

    # Iniciar sitio FTP (delay para que IIS registre el sitio correctamente)
    Start-Sleep -Seconds 2
    try {
        Start-WebSite -Name $SITIO_FTP -ErrorAction Stop
        Registrar "Sitio FTP iniciado correctamente." "OK"
    } catch {
        Registrar "Advertencia al iniciar el sitio, intentando con iisreset..." "INFO"
        iisreset /restart | Out-Null
        Start-Sleep -Seconds 3
        Start-WebSite -Name $SITIO_FTP -ErrorAction SilentlyContinue
    }
    Registrar "Entorno FTP listo y sitio activo." "OK"
}

# Crea el usuario local, lo agrega al grupo, crea su estructura
# de directorios y asigna permisos NTFS correspondientes.
function Crear-Usuario {
    param(
        [string]$Usuario,
        [string]$Contrasena,
        [string]$Grupo
    )

    # Crear usuario local del sistema
    $pass = ConvertTo-SecureString $Contrasena -AsPlainText -Force
    New-LocalUser -Name $Usuario -Password $pass -PasswordNeverExpires $true -UserMayNotChangePassword $false | Out-Null
    Add-LocalGroupMember -Group $Grupo -Member $Usuario
    Registrar "Usuario '$Usuario' creado y agregado al grupo '$Grupo'." "OK"

    # Estructura de directorios del usuario
    # IIS con aislamiento busca: \LocalUser\<usuario> como raíz del chroot
    $raiz_chroot = "$RAIZ_USUARIOS\LocalUser\$Usuario"
    $carpetas = @(
        "$raiz_chroot\$Usuario",
        "$raiz_chroot\general",
        "$raiz_chroot\$Grupo"
    )
    foreach ($carpeta in $carpetas) {
        if (!(Test-Path $carpeta)) {
            New-Item -ItemType Directory -Path $carpeta -Force | Out-Null
        }
    }

    # Permisos carpeta personal: solo el usuario
    Asignar-Permiso -Ruta "$raiz_chroot\$Usuario" -Identidad "$env:COMPUTERNAME\$Usuario" -Permiso "Modify"

    # Junction de general en chroot del usuario
    $junctionGeneral = "$raiz_chroot\general"
    if (!(Test-Path $junctionGeneral)) {
        cmd /c "mklink /J `"$junctionGeneral`" `"$CARPETA_GENERAL`"" | Out-Null
    }
    Asignar-Permiso -Ruta $CARPETA_GENERAL -Identidad "$env:COMPUTERNAME\$Usuario" -Permiso "Modify"

    # Junction de grupo en chroot del usuario
    $junctionGrupo = "$raiz_chroot\$Grupo"
    if (!(Test-Path $junctionGrupo)) {
        cmd /c "mklink /J `"$junctionGrupo`" `"$RAIZ_GRUPOS\$Grupo`"" | Out-Null
    }
    Asignar-Permiso -Ruta "$RAIZ_GRUPOS\$Grupo" -Identidad "$env:COMPUTERNAME\$Usuario" -Permiso "Modify"

    Registrar "Estructura de directorios y permisos asignados a '$Usuario'." "OK"
}

function Alta-Usuario {
    Write-Host ""
    Write-Host "-- Alta de usuario FTP --"

    $usuario = Read-Host "Nombre de usuario"
    $usuario = $usuario.Trim()

    if ([string]::IsNullOrEmpty($usuario)) {
        Registrar "El nombre de usuario no puede estar vacío." "ERROR"
        return
    }
    if (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue) {
        Registrar "El usuario '$usuario' ya existe en el sistema." "ERROR"
        return
    }

    $contrasena = Read-Host "Contraseña (8-15 chars, mayúscula, minúscula, número, especial)" -AsSecureString
    $contrasenaPlana = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($contrasena)
    )
    if (!(Validar-Contrasena -Contrasena $contrasenaPlana)) {
        Registrar "La contraseña no cumple los requisitos de seguridad." "ERROR"
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
            Registrar "Opción de grupo no válida." "ERROR"
            return
        }
    }

    Crear-Usuario -Usuario $usuario -Contrasena $contrasenaPlana -Grupo $grupo
}

function Alta-Masiva {
    Write-Host ""
    Write-Host "-- Alta masiva de usuarios FTP --"

    $cantidad = Read-Host "¿Cuántos usuarios deseas registrar?"
    if ($cantidad -notmatch '^\d+$' -or [int]$cantidad -le 0) {
        Registrar "Cantidad inválida. Ingresa un número entero positivo." "ERROR"
        return
    }

    $creados  = 0
    $omitidos = 0

    for ($i = 1; $i -le [int]$cantidad; $i++) {
        Write-Host ""
        Write-Host "-- Usuario $i de $cantidad --"

        $usuario = (Read-Host "  Nombre de usuario").Trim()
        if ([string]::IsNullOrEmpty($usuario)) {
            Registrar "Nombre vacío, se omite el usuario $i." "ERROR"
            $omitidos++
            continue
        }
        if (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue) {
            Registrar "El usuario '$usuario' ya existe, se omite." "ERROR"
            $omitidos++
            continue
        }

        $contrasena = Read-Host "  Contraseña" -AsSecureString
        $contrasenaPlana = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($contrasena)
        )
        if (!(Validar-Contrasena -Contrasena $contrasenaPlana)) {
            Registrar "Contraseña inválida para '$usuario', se omite." "ERROR"
            $omitidos++
            continue
        }

        Write-Host "  Grupos: 1) reprobados   2) recursadores"
        $opcion = Read-Host "  Grupo"

        switch ($opcion) {
            "1" { $grupo = "reprobados" }
            "2" { $grupo = "recursadores" }
            default {
                Registrar "Grupo inválido para '$usuario', se omite." "ERROR"
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

    # Detectar grupo actual
    $grupo_actual = $null
    foreach ($g in @("reprobados", "recursadores")) {
        $miembros = Get-LocalGroupMember -Group $g -ErrorAction SilentlyContinue
        if ($miembros | Where-Object { $_.Name -like "*\$usuario" }) {
            $grupo_actual = $g
            break
        }
    }

    if ($null -eq $grupo_actual) {
        Registrar "El usuario '$usuario' no pertenece a ningún grupo FTP conocido." "ERROR"
        return
    }

    $grupo_nuevo = if ($grupo_actual -eq "reprobados") { "recursadores" } else { "reprobados" }

    Write-Host "El usuario '$usuario' pertenece actualmente a: $grupo_actual"
    $confirmacion = Read-Host "¿Moverlo a '$grupo_nuevo'? (s/N)"
    if ($confirmacion -notmatch '^[Ss]$') {
        Registrar "Cambio de grupo cancelado." "INFO"
        return
    }

    # Cambiar grupo
    Remove-LocalGroupMember -Group $grupo_actual -Member $usuario
    Add-LocalGroupMember -Group $grupo_nuevo -Member $usuario

    $raiz_chroot = "$RAIZ_USUARIOS\LocalUser\$usuario"

    # Revocar permisos en grupo anterior
    $acl = Get-Acl "$RAIZ_GRUPOS\$grupo_actual"
    $acl.Access | Where-Object { $_.IdentityReference -like "*\$usuario" } | ForEach-Object {
        $acl.RemoveAccessRule($_) | Out-Null
    }
    Set-Acl -Path "$RAIZ_GRUPOS\$grupo_actual" -AclObject $acl

    # Asignar permisos en grupo nuevo
    Asignar-Permiso -Ruta "$RAIZ_GRUPOS\$grupo_nuevo" -Identidad "$env:COMPUTERNAME\$usuario" -Permiso "Modify"

    # Actualizar junction de grupo en chroot
    $junctionAntiguo = "$raiz_chroot\$grupo_actual"
    if (Test-Path $junctionAntiguo) {
        cmd /c "rmdir `"$junctionAntiguo`"" | Out-Null
    }
    $junctionNuevo = "$raiz_chroot\$grupo_nuevo"
    if (!(Test-Path $junctionNuevo)) {
        New-Item -ItemType Directory -Path $junctionNuevo -Force | Out-Null
        cmd /c "rmdir `"$junctionNuevo`"" | Out-Null
        cmd /c "mklink /J `"$junctionNuevo`" `"$RAIZ_GRUPOS\$grupo_nuevo`"" | Out-Null
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
    Write-Host "ADVERTENCIA: Esta acción elimina al usuario y todos sus archivos. No se puede deshacer." -ForegroundColor Red
    $confirmacion = Read-Host "Escribe el nombre del usuario para confirmar"

    if ($confirmacion -ne $usuario) {
        Registrar "Confirmación incorrecta. No se realizó ningún cambio." "ERROR"
        return
    }

    # Eliminar junctions del chroot antes de borrar carpetas
    $raiz_chroot = "$RAIZ_USUARIOS\LocalUser\$usuario"
    foreach ($junction in @("general", "reprobados", "recursadores")) {
        $path = "$raiz_chroot\$junction"
        if (Test-Path $path) {
            cmd /c "rmdir `"$path`"" | Out-Null
        }
    }

    # Revocar permisos en carpetas compartidas
    foreach ($ruta in @($CARPETA_GENERAL, "$RAIZ_GRUPOS\reprobados", "$RAIZ_GRUPOS\recursadores")) {
        if (Test-Path $ruta) {
            $acl = Get-Acl $ruta
            $acl.Access | Where-Object { $_.IdentityReference -like "*\$usuario" } | ForEach-Object {
                $acl.RemoveAccessRule($_) | Out-Null
            }
            Set-Acl -Path $ruta -AclObject $acl
        }
    }

    # Eliminar usuario del sistema
    Remove-LocalUser -Name $usuario

    # Eliminar directorio chroot
    if (Test-Path $raiz_chroot) {
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
    Write-Host " 6. Reiniciar sitio FTP"
    Write-Host " 7. Salir"
    Write-Host "-----------------------------------------"
    $opcion = Read-Host " Opción"

    switch ($opcion) {
        "1" { Alta-Usuario }
        "2" { Alta-Masiva }
        "3" { Cambiar-Grupo }
        "4" { Eliminar-Usuario }
        "5" { Listar-Usuarios }
        "6" {
            Stop-WebSite -Name $SITIO_FTP
            Start-WebSite -Name $SITIO_FTP
            Registrar "Sitio FTP reiniciado manualmente." "OK"
        }
        "7" {
            Registrar "Sesión terminada." "INFO"
            exit 0
        }
        default { Write-Host "Opción no reconocida. Intenta de nuevo." }
    }
}
