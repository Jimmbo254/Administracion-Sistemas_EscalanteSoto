# Servicio FTP - Windows

# --- Rutas base ---
$RAIZ_FTP        = "C:\inetpub\ftp"
$RAIZ_USUARIOS   = "$RAIZ_FTP\usuarios"
$RAIZ_GRUPOS     = "$RAIZ_FTP\grupos"
$CARPETA_GENERAL = "$RAIZ_FTP\general"
$CARPETA_ANONIMO = "$RAIZ_FTP\anonimo"
$SITIO_FTP       = "ServidorFTP"
$PUERTO_FTP      = 21
$ARCHIVO_LOG     = "C:\logs\gestion_ftp.log"

#=============== FUNCIONES ====================

function Registrar {
    param(
        [string]$Mensaje,
        [string]$Tipo = "INFO"
    )
    $fecha = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $linea = "[$fecha] [$Tipo] $Mensaje"
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
        [string]$Identidad,
        [string]$Permiso,
        [string]$Tipo = "Allow"
    )
    try {
        $acl    = Get-Acl $Ruta
        $cuenta = New-Object System.Security.Principal.NTAccount($Identidad)
        $regla  = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $cuenta, $Permiso, "ContainerInherit,ObjectInherit", "None", $Tipo
        )
        $acl.AddAccessRule($regla)
        Set-Acl -Path $Ruta -AclObject $acl
    } catch {
        Registrar "Advertencia al asignar permiso en '$Ruta' para '$Identidad': $_" "INFO"
    }
}

function Revocar-Permiso {
    param(
        [string]$Ruta,
        [string]$Usuario
    )
    try {
        if (!(Test-Path $Ruta)) { return }
        $acl = Get-Acl $Ruta
        $acl.Access |
            Where-Object { $_.IdentityReference -like "*\$Usuario" } |
            ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
        Set-Acl -Path $Ruta -AclObject $acl
    } catch {
        Registrar "Advertencia al revocar permiso en '$Ruta' para '$Usuario': $_" "INFO"
    }
}

# Aplica permisos Modify sobre la carpeta general para un usuario:
# - Sobre el destino real ($CARPETA_GENERAL)
# - Sobre la junction dentro del chroot del usuario
# IIS evalua permisos en ambos puntos, por eso se necesitan los dos.
function Asignar-PermisosGeneral {
    param(
        [string]$Usuario,
        [string]$RaizChroot
    )
    # Permiso sobre el destino real
    Asignar-Permiso -Ruta $CARPETA_GENERAL -Identidad "$env:COMPUTERNAME\$Usuario" -Permiso "Modify"

    # Permiso sobre la junction misma dentro del chroot
    $junctionGeneral = "$RaizChroot\general"
    if (Test-Path $junctionGeneral) {
        Asignar-Permiso -Ruta $junctionGeneral -Identidad "$env:COMPUTERNAME\$Usuario" -Permiso "Modify"
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

    foreach ($grupo in @("reprobados", "recursadores")) {
        if (!(Get-LocalGroup -Name $grupo -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $grupo -Description "Grupo FTP $grupo"
            Registrar "Grupo local '$grupo' creado." "OK"
        }
    }

    # BUILTIN\Usuarios solo lectura en general: el Modify se asigna
    # individualmente a cada usuario al crearlo via Asignar-PermisosGeneral.
    # IIS_IUSRS (cuenta del anonimo) tambien solo lectura.
    Asignar-Permiso -Ruta $CARPETA_GENERAL -Identidad "BUILTIN\Usuarios"  -Permiso "ReadAndExecute"
    Asignar-Permiso -Ruta $CARPETA_GENERAL -Identidad "BUILTIN\IIS_IUSRS" -Permiso "ReadAndExecute"
    Asignar-Permiso -Ruta $CARPETA_ANONIMO -Identidad "BUILTIN\IIS_IUSRS" -Permiso "ReadAndExecute"

    $junctionPath = "$CARPETA_ANONIMO\general"
    if (!(Test-Path $junctionPath)) {
        cmd /c "mklink /J `"$junctionPath`" `"$CARPETA_GENERAL`"" | Out-Null
        Registrar "Junction de general en anonimo creado." "OK"
    }

    # Carpeta Public para acceso anonimo (IIS busca LocalUser\Public)
    $carpetaPublic = "$RAIZ_USUARIOS\LocalUser\Public"
    if (!(Test-Path $carpetaPublic)) {
        New-Item -ItemType Directory -Path $carpetaPublic -Force | Out-Null
        Registrar "Carpeta Public para anonimo creada." "OK"
    }
    $junctionPublic = "$carpetaPublic\general"
    if (!(Test-Path $junctionPublic)) {
        cmd /c "mklink /J `"$junctionPublic`" `"$CARPETA_GENERAL`"" | Out-Null
        Registrar "Junction de general en Public creado." "OK"
    }

    foreach ($grupo in @("reprobados", "recursadores")) {
        Asignar-Permiso -Ruta "$RAIZ_GRUPOS\$grupo" -Identidad "$env:COMPUTERNAME\$grupo" -Permiso "Modify"
    }

    if (Get-WebSite -Name $SITIO_FTP -ErrorAction SilentlyContinue) {
        Remove-WebSite -Name $SITIO_FTP
        Registrar "Sitio FTP anterior eliminado para reconfigurar." "INFO"
    }

    # PhysicalPath apunta a usuarios para que IIS encuentre LocalUser\<usuario>
    New-WebFtpSite -Name $SITIO_FTP -Port $PUERTO_FTP -PhysicalPath $RAIZ_USUARIOS -Force | Out-Null
    Registrar "Sitio FTP '$SITIO_FTP' creado en puerto $PUERTO_FTP." "OK"

    Set-ItemProperty "IIS:\Sites\$SITIO_FTP" -Name ftpServer.security.authentication.anonymousAuthentication.enabled -Value $true
    Set-ItemProperty "IIS:\Sites\$SITIO_FTP" -Name ftpServer.security.authentication.basicAuthentication.enabled -Value $true

    # Deshabilitar SSL para permitir conexiones sin cifrado
    Set-ItemProperty "IIS:\Sites\$SITIO_FTP" -Name ftpServer.security.ssl.controlChannelPolicy -Value 0
    Set-ItemProperty "IIS:\Sites\$SITIO_FTP" -Name ftpServer.security.ssl.dataChannelPolicy -Value 0

    Add-WebConfiguration "/system.ftpServer/security/authorization" -Value @{
        accessType  = "Allow"
        users       = ""
        roles       = ""
        permissions = "Read"
    } -PSPath "IIS:\" -Location "$SITIO_FTP"

    Add-WebConfiguration "/system.ftpServer/security/authorization" -Value @{
        accessType  = "Allow"
        users       = "*"
        roles       = ""
        permissions = "Read,Write"
    } -PSPath "IIS:\" -Location "$SITIO_FTP"

    # Denegar escritura explicitamente al anonimo (anula la regla Allow Write de arriba)
    Add-WebConfiguration "/system.ftpServer/security/authorization" -Value @{
        accessType  = "Deny"
        users       = ""
        roles       = ""
        permissions = "Write"
    } -PSPath "IIS:\" -Location "$SITIO_FTP"

    Set-ItemProperty "IIS:\Sites\$SITIO_FTP" -Name ftpServer.userIsolation.mode -Value "IsolateAllDirectories"

    $reglaFirewall = Get-NetFirewallRule -DisplayName "FTP Puerto 21" -ErrorAction SilentlyContinue
    if (-not $reglaFirewall) {
        New-NetFirewallRule -DisplayName "FTP Puerto 21" -Direction Inbound -Protocol TCP -LocalPort 21 -Action Allow | Out-Null
        Registrar "Puerto 21 habilitado en firewall de Windows." "OK"
    }

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

    Asignar-Permiso -Ruta "$raiz_chroot\$Usuario" -Identidad "$env:COMPUTERNAME\$Usuario" -Permiso "Modify"

    # Junction de general: permisos sobre destino real Y sobre la junction
    $junctionGeneral = "$raiz_chroot\general"
    if (Test-Path $junctionGeneral) {
        cmd /c "rmdir `"$junctionGeneral`"" | Out-Null
    }
    cmd /c "mklink /J `"$junctionGeneral`" `"$CARPETA_GENERAL`"" | Out-Null
    Asignar-PermisosGeneral -Usuario $Usuario -RaizChroot $raiz_chroot

    # Junction de grupo: permisos sobre destino real
    $junctionGrupo = "$raiz_chroot\$Grupo"
    if (Test-Path $junctionGrupo) {
        cmd /c "rmdir `"$junctionGrupo`"" | Out-Null
    }
    cmd /c "mklink /J `"$junctionGrupo`" `"$RAIZ_GRUPOS\$Grupo`"" | Out-Null
    Asignar-Permiso -Ruta "$RAIZ_GRUPOS\$Grupo" -Identidad "$env:COMPUTERNAME\$Usuario" -Permiso "Modify"

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

    $raiz_chroot = "$RAIZ_USUARIOS\LocalUser\$usuario"

    # Revocar permiso del usuario sobre el grupo anterior
    Revocar-Permiso -Ruta "$RAIZ_GRUPOS\$grupo_actual" -Usuario $usuario

    # Asignar permiso sobre el grupo nuevo
    Asignar-Permiso -Ruta "$RAIZ_GRUPOS\$grupo_nuevo" -Identidad "$env:COMPUTERNAME\$usuario" -Permiso "Modify"

    # Actualizar junction del grupo en el chroot
    $junctionAntiguo = "$raiz_chroot\$grupo_actual"
    if (Test-Path $junctionAntiguo) {
        cmd /c "rmdir `"$junctionAntiguo`"" | Out-Null
    }
    $junctionNuevo = "$raiz_chroot\$grupo_nuevo"
    if (Test-Path $junctionNuevo) {
        cmd /c "rmdir `"$junctionNuevo`"" | Out-Null
    }
    New-Item -ItemType Directory -Path $junctionNuevo -Force | Out-Null
    cmd /c "rmdir `"$junctionNuevo`"" | Out-Null
    cmd /c "mklink /J `"$junctionNuevo`" `"$RAIZ_GRUPOS\$grupo_nuevo`"" | Out-Null

    # FIX: re-crear junction de general y re-aplicar permisos sobre destino
    # real Y sobre la junction misma. IIS evalua permisos en ambos puntos.
    $junctionGeneral = "$raiz_chroot\general"
    if (Test-Path $junctionGeneral) {
        cmd /c "rmdir `"$junctionGeneral`"" | Out-Null
    }
    cmd /c "mklink /J `"$junctionGeneral`" `"$CARPETA_GENERAL`"" | Out-Null
    Revocar-Permiso -Ruta $CARPETA_GENERAL -Usuario $usuario
    Asignar-PermisosGeneral -Usuario $usuario -RaizChroot $raiz_chroot

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

    $raiz_chroot = "$RAIZ_USUARIOS\LocalUser\$usuario"
    foreach ($junction in @("general", "reprobados", "recursadores")) {
        $path = "$raiz_chroot\$junction"
        if (Test-Path $path) {
            cmd /c "rmdir `"$path`"" | Out-Null
        }
    }

    # Revocar todas las entradas ACL del usuario en carpetas compartidas
    foreach ($ruta in @($CARPETA_GENERAL, "$RAIZ_GRUPOS\reprobados", "$RAIZ_GRUPOS\recursadores")) {
        Revocar-Permiso -Ruta $ruta -Usuario $usuario
    }

    Remove-LocalUser -Name $usuario

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
    $opcion = Read-Host " Opcion"

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
            Registrar "Sesion terminada." "INFO"
            exit 0
        }
        default { Write-Host "Opcion no reconocida. Intenta de nuevo." }
    }
}
