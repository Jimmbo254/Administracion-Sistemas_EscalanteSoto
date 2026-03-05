#!/bin/bash

# Servidor FTP - Fedora

VERDE='\033[0;32m'
ROJO='\033[0;31m'
NORMAL='\033[0m'

ARCHIVO_LOG='/var/log/gestion_ftp.log'

# Rutas Base
RAIZ_FTP="/srv/ftp"
RAIZ_USUARIOS="$RAIZ_FTP/usuarios"
RAIZ_GRUPOS="$RAIZ_FTP/grupos"
CARPETA_GENERAL="$RAIZ_FTP/general"
CONF_VSFTPD="/etc/vsftpd/vsftpd.conf"
LISTA_USUARIOS="/etc/vsftpd/user_list"

# ============== FUNCIONES ==============

# Registra un mensaje en el log y lo muestra en pantalla
registrar() {
    local mensaje="$1"
    local tipo="${2:-INFO}"
    local fecha
    fecha=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$fecha] [$tipo] $mensaje" >> "$ARCHIVO_LOG"

    if [[ "$tipo" == "OK" ]]; then
        echo -e "${VERDE}[$tipo] $mensaje${NORMAL}"
    elif [[ "$tipo" == "ERROR" ]]; then
        echo -e "${ROJO}[$tipo] $mensaje${NORMAL}"
    else
        echo "[$tipo] $mensaje"
    fi
}

# Verifica que el script corra como root
verificar_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${ROJO}[ERROR] Necesitas ejecutar este script con privilegios de root (sudo).${NORMAL}"
        exit 1
    fi
}

# Valida que la contraseña cumpla requisitos de seguridad:
# - Entre 8 y 15 caracteres
# - Al menos una mayúscula, una minúscula, un número y un carácter especial
validar_contrasena() {
    local contrasena="$1"
    local longitud=${#contrasena}

    if [[ $longitud -lt 8 || $longitud -gt 15 ]]; then
        return 1
    fi
    if ! echo "$contrasena" | grep -q '[A-Z]'; then return 1; fi
    if ! echo "$contrasena" | grep -q '[a-z]'; then return 1; fi
    if ! echo "$contrasena" | grep -q '[0-9]'; then return 1; fi
    if ! echo "$contrasena" | grep -q '[^a-zA-Z0-9]'; then return 1; fi
    return 0
}

# Instala vsftpd si no está presente, crea la estructura de
# directorios, configura vsftpd.conf, ajusta firewall y SELinux.
# Es seguro ejecutarlo varias veces (idempotente).
instalar_entorno() {
    registrar "Verificando instalación de vsftpd..." "INFO"

    # Instalar vsftpd solo si no está instalado
    if ! rpm -q vsftpd &>/dev/null; then
        dnf install -y vsftpd &>/dev/null
        registrar "vsftpd instalado correctamente." "OK"
    else
        registrar "vsftpd ya estaba instalado, no se reinstala." "INFO"
    fi

    # Instalar acl para manejo de permisos extendidos
    if ! rpm -q acl &>/dev/null; then
        dnf install -y acl &>/dev/null
        registrar "Paquete acl instalado." "OK"
    fi

    # Crear estructura base de directorios
    local directorios=(
        "$CARPETA_GENERAL"
        "$RAIZ_USUARIOS"
        "$RAIZ_GRUPOS/reprobados"
        "$RAIZ_GRUPOS/recursadores"
    )
    for dir in "${directorios[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            registrar "Directorio creado: $dir" "INFO"
        fi
    done

    # Crear grupos del sistema si no existen
    for grupo in reprobados recursadores; do
        if ! getent group "$grupo" &>/dev/null; then
            groupadd "$grupo"
            registrar "Grupo del sistema '$grupo' creado." "OK"
        fi
    done

    # Permisos en carpeta general: root la posee, todos pueden leer/ejecutar
    # Los usuarios autenticados tendrán ACL de escritura
    chown root:root "$CARPETA_GENERAL"
    chmod 755 "$CARPETA_GENERAL"

    # Permisos en carpetas de grupo: el grupo tiene escritura
    for grupo in reprobados recursadores; do
        chown root:"$grupo" "$RAIZ_GRUPOS/$grupo"
        chmod 775 "$RAIZ_GRUPOS/$grupo"
    done

    # Generar archivo vsftpd.conf
    cp "$CONF_VSFTPD" "${CONF_VSFTPD}.respaldo" 2>/dev/null
    cat > "$CONF_VSFTPD" << 'FINCONF'
# -------------------------------------------------------
# Configuración vsftpd - Servidor FTP Fedora
# -------------------------------------------------------

# Modo de escucha
listen=YES
listen_ipv6=NO

# Acceso de usuarios
anonymous_enable=YES
local_enable=YES
write_enable=YES
local_umask=022

# Opciones de acceso anónimo (solo lectura en /general)
anon_root=/srv/ftp
no_anon_password=YES
anon_upload_enable=NO
anon_mkdir_write_enable=NO
anon_other_write_enable=NO

# Registro de transferencias
xferlog_enable=YES
xferlog_std_format=YES
use_localtime=YES
dirmessage_enable=YES
connect_from_port_20=YES

# Jaula chroot: cada usuario queda encerrado en su directorio
chroot_local_user=YES
allow_writeable_chroot=YES
secure_chroot_dir=/var/run/vsftpd/empty

# Autenticación PAM
pam_service_name=vsftpd

# Lista blanca de usuarios permitidos
userlist_enable=YES
userlist_deny=NO
userlist_file=/etc/vsftpd/user_list

# Directorio raíz por usuario (se resuelve dinámicamente)
user_sub_token=$USER
local_root=/srv/ftp/usuarios/$USER
FINCONF

    # Crear lista de usuarios si no existe, agregar ftp (anónimo)
    touch "$LISTA_USUARIOS"
    if ! grep -q "^ftp$" "$LISTA_USUARIOS" 2>/dev/null; then
        echo "ftp" >> "$LISTA_USUARIOS"
    fi

    # Abrir puerto FTP en el firewall
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-service=ftp &>/dev/null
        firewall-cmd --reload &>/dev/null
        registrar "Puerto 21 habilitado en firewall." "OK"
    fi

    # Ajustes SELinux para vsftpd
    if command -v setsebool &>/dev/null; then
        setsebool -P ftpd_full_access on &>/dev/null
        setsebool -P allow_ftpd_full_access on &>/dev/null
        registrar "SELinux configurado para vsftpd." "OK"
    fi

    # Habilitar e iniciar el servicio
    systemctl enable vsftpd &>/dev/null
    systemctl restart vsftpd

    registrar "Entorno FTP listo y servicio activo." "OK"
}


# Crea el usuario en el sistema, asigna grupo, construye la
# estructura de directorios dentro de su chroot y aplica ACLs.
# Parámetros: $1=nombre_usuario  $2=contrasena  $3=grupo
crear_usuario() {
    local usuario="$1"
    local contrasena="$2"
    local grupo="$3"

    # Crear usuario del sistema sin shell de login ni directorio home
    useradd -M -s /sbin/nologin "$usuario"
    echo "$usuario:$contrasena" | chpasswd
    usermod -aG "$grupo" "$usuario"

    local raiz_chroot="$RAIZ_USUARIOS/$usuario"
    mkdir -p "$raiz_chroot/$usuario"
    mkdir -p "$raiz_chroot/general"
    mkdir -p "$raiz_chroot/$grupo"

    # Raíz del chroot debe ser propiedad de root (requisito vsftpd)
    chown root:root "$raiz_chroot"
    chmod 755 "$raiz_chroot"

    # Carpeta personal: solo el usuario tiene acceso total
    chown "$usuario":"$usuario" "$raiz_chroot/$usuario"
    chmod 700 "$raiz_chroot/$usuario"

    # Montar carpeta general dentro del chroot
    mount --bind "$CARPETA_GENERAL" "$raiz_chroot/general" 2>/dev/null || \
        ln -sfn "$CARPETA_GENERAL" "$raiz_chroot/general"

    # Montar carpeta de grupo dentro del chroot
    mount --bind "$RAIZ_GRUPOS/$grupo" "$raiz_chroot/$grupo" 2>/dev/null || \
        ln -sfn "$RAIZ_GRUPOS/$grupo" "$raiz_chroot/$grupo"

    # ACLs: usuario autenticado tiene escritura en general y en su grupo
    setfacl -m "u:$usuario:rwx" "$CARPETA_GENERAL"
    setfacl -d -m "u:$usuario:rwx" "$CARPETA_GENERAL"
    setfacl -m "u:$usuario:rwx" "$RAIZ_GRUPOS/$grupo"
    setfacl -d -m "u:$usuario:rwx" "$RAIZ_GRUPOS/$grupo"

    # Agregar a la lista blanca de vsftpd
    if ! grep -q "^$usuario$" "$LISTA_USUARIOS"; then
        echo "$usuario" >> "$LISTA_USUARIOS"
    fi

    registrar "Usuario '$usuario' creado y asignado al grupo '$grupo'." "OK"
}

alta_usuario() {
    echo ""
    echo "-- Alta de usuario FTP --"

    read -rp "Nombre de usuario: " usuario
    usuario=$(echo "$usuario" | tr -d '[:space:]')

    if [[ -z "$usuario" ]]; then
        registrar "El nombre de usuario no puede estar vacío." "ERROR"
        return
    fi
    if id "$usuario" &>/dev/null; then
        registrar "El usuario '$usuario' ya existe en el sistema." "ERROR"
        return
    fi

    read -rsp "Contraseña (8-15 chars, mayúscula, minúscula, número, especial): " contrasena
    echo
    if ! validar_contrasena "$contrasena"; then
        registrar "La contraseña no cumple los requisitos de seguridad." "ERROR"
        return
    fi

    echo "Grupos disponibles:"
    echo "  1) reprobados"
    echo "  2) recursadores"
    read -rp "Selecciona el grupo del usuario: " opcion_grupo

    case "$opcion_grupo" in
        1) grupo="reprobados" ;;
        2) grupo="recursadores" ;;
        *)
            registrar "Opción de grupo no válida." "ERROR"
            return
            ;;
    esac

    crear_usuario "$usuario" "$contrasena" "$grupo"
}


alta_masiva() {
    echo ""
    echo "-- Alta masiva de usuarios FTP --"

    read -rp "¿Cuántos usuarios deseas registrar? " cantidad

    if ! [[ "$cantidad" =~ ^[0-9]+$ ]] || [[ "$cantidad" -le 0 ]]; then
        registrar "Cantidad inválida. Ingresa un número entero positivo." "ERROR"
        return
    fi

    local creados=0
    local omitidos=0

    for (( i=1; i<=cantidad; i++ )); do
        echo ""
        echo "-- Usuario $i de $cantidad --"

        read -rp "  Nombre de usuario: " usuario
        usuario=$(echo "$usuario" | tr -d '[:space:]')

        if [[ -z "$usuario" ]]; then
            registrar "Nombre vacío, se omite el usuario $i." "ERROR"
            (( omitidos++ ))
            continue
        fi
        if id "$usuario" &>/dev/null; then
            registrar "El usuario '$usuario' ya existe, se omite." "ERROR"
            (( omitidos++ ))
            continue
        fi

        read -rsp "  Contraseña: " contrasena
        echo
        if ! validar_contrasena "$contrasena"; then
            registrar "Contraseña inválida para '$usuario', se omite." "ERROR"
            (( omitidos++ ))
            continue
        fi

        echo "  Grupos: 1) reprobados   2) recursadores"
        read -rp "  Grupo: " opcion_grupo

        case "$opcion_grupo" in
            1) grupo="reprobados" ;;
            2) grupo="recursadores" ;;
            *)
                registrar "Grupo inválido para '$usuario', se omite." "ERROR"
                (( omitidos++ ))
                continue
                ;;
        esac

        crear_usuario "$usuario" "$contrasena" "$grupo"
        (( creados++ ))
    done

    echo ""
    registrar "Alta masiva completada. Creados: $creados | Omitidos: $omitidos." "OK"
}

cambiar_grupo() {
    echo ""
    echo "-- Cambio de grupo --"

    read -rp "Nombre de usuario: " usuario
    usuario=$(echo "$usuario" | tr -d '[:space:]')

    if ! id "$usuario" &>/dev/null; then
        registrar "El usuario '$usuario' no existe." "ERROR"
        return
    fi

    # Detectar grupo FTP actual del usuario
    local grupo_actual=""
    for g in reprobados recursadores; do
        if id -nG "$usuario" | grep -qw "$g"; then
            grupo_actual="$g"
            break
        fi
    done

    if [[ -z "$grupo_actual" ]]; then
        registrar "El usuario '$usuario' no pertenece a ningún grupo FTP conocido." "ERROR"
        return
    fi

    local grupo_nuevo
    if [[ "$grupo_actual" == "reprobados" ]]; then
        grupo_nuevo="recursadores"
    else
        grupo_nuevo="reprobados"
    fi

    echo "El usuario '$usuario' pertenece actualmente a: $grupo_actual"
    read -rp "¿Moverlo a '$grupo_nuevo'? (s/N): " confirmacion

    if [[ ! "$confirmacion" =~ ^[Ss]$ ]]; then
        registrar "Cambio de grupo cancelado por el usuario." "INFO"
        return
    fi

    # Quitar del grupo anterior y agregar al nuevo
    gpasswd -d "$usuario" "$grupo_actual" &>/dev/null
    usermod -aG "$grupo_nuevo" "$usuario"

    local raiz_chroot="$RAIZ_USUARIOS/$usuario"

    # Revocar ACL en grupo anterior
    setfacl -x "u:$usuario" "$RAIZ_GRUPOS/$grupo_actual" 2>/dev/null

    # Asignar ACL en grupo nuevo
    setfacl -m "u:$usuario:rwx" "$RAIZ_GRUPOS/$grupo_nuevo"
    setfacl -d -m "u:$usuario:rwx" "$RAIZ_GRUPOS/$grupo_nuevo"

    # Actualizar estructura de directorios del chroot
    umount "$raiz_chroot/$grupo_actual" 2>/dev/null
    rm -rf "$raiz_chroot/$grupo_actual"
    mkdir -p "$raiz_chroot/$grupo_nuevo"

    mount --bind "$RAIZ_GRUPOS/$grupo_nuevo" "$raiz_chroot/$grupo_nuevo" 2>/dev/null || \
        ln -sfn "$RAIZ_GRUPOS/$grupo_nuevo" "$raiz_chroot/$grupo_nuevo"

    # Mantener permisos correctos en la raíz del chroot
    chown root:root "$raiz_chroot"
    chmod 755 "$raiz_chroot"

    registrar "Usuario '$usuario' movido de '$grupo_actual' a '$grupo_nuevo'." "OK"
}

eliminar_usuario() {
    echo ""
    echo "-- Eliminar usuario FTP --"

    read -rp "Nombre de usuario a eliminar: " usuario
    usuario=$(echo "$usuario" | tr -d '[:space:]')

    if ! id "$usuario" &>/dev/null; then
        registrar "El usuario '$usuario' no existe en el sistema." "ERROR"
        return
    fi

    echo ""
    echo -e "${ROJO}ADVERTENCIA: Esta acción elimina al usuario y todos sus archivos. No se puede deshacer.${NORMAL}"
    read -rp "Escribe el nombre del usuario para confirmar: " confirmacion

    if [[ "$confirmacion" != "$usuario" ]]; then
        registrar "Confirmación incorrecta. No se realizó ningún cambio." "ERROR"
        return
    fi

    # Desmontar bind mounts del chroot
    umount "$RAIZ_USUARIOS/$usuario/general"       2>/dev/null
    umount "$RAIZ_USUARIOS/$usuario/reprobados"    2>/dev/null
    umount "$RAIZ_USUARIOS/$usuario/recursadores"  2>/dev/null

    # Revocar ACLs en carpetas compartidas
    setfacl -x "u:$usuario" "$CARPETA_GENERAL"              2>/dev/null
    setfacl -x "u:$usuario" "$RAIZ_GRUPOS/reprobados"       2>/dev/null
    setfacl -x "u:$usuario" "$RAIZ_GRUPOS/recursadores"     2>/dev/null

    # Quitar de la lista blanca de vsftpd
    sed -i "/^$usuario$/d" "$LISTA_USUARIOS"

    # Eliminar usuario del sistema y su directorio chroot
    userdel "$usuario" 2>/dev/null
    rm -rf "$RAIZ_USUARIOS/$usuario"

    registrar "Usuario '$usuario' eliminado correctamente." "OK"
}

listar_usuarios() {
    echo ""
    echo "-- Usuarios FTP registrados por grupo --"

    for grupo in reprobados recursadores; do
        echo ""
        echo "Grupo: $grupo"
        local miembros
        miembros=$(getent group "$grupo" | cut -d: -f4 | tr ',' '\n')

        if [[ -z "$miembros" ]]; then
            echo "  (sin usuarios asignados)"
        else
            while IFS= read -r miembro; do
                echo "  -> $miembro"
            done <<< "$miembros"
        fi
    done
    echo ""
}

# MENU

verificar_root
instalar_entorno

while true; do
    echo ""
    echo "========================================="
    echo "         ADMINISTRADOR FTP - FEDORA      "
    echo "========================================="
    echo " 1. Registrar un usuario"
    echo " 2. Registro masivo de usuarios"
    echo " 3. Cambiar usuario de grupo"
    echo " 4. Eliminar usuario"
    echo " 5. Listar usuarios por grupo"
    echo " 6. Reiniciar servicio vsftpd"
    echo " 7. Salir"
    echo "-----------------------------------------"
    read -rp " Opción: " opcion

    case "$opcion" in
        1) alta_usuario     ;;
        2) alta_masiva      ;;
        3) cambiar_grupo    ;;
        4) eliminar_usuario ;;
        5) listar_usuarios  ;;
        6)
            systemctl restart vsftpd
            registrar "Servicio vsftpd reiniciado manualmente." "OK"
            ;;
        7)
            registrar "Sesión terminada." "INFO"
            exit 0
            ;;
        *)
            echo "Opción no reconocida. Intenta de nuevo."
            ;;
    esac
done
