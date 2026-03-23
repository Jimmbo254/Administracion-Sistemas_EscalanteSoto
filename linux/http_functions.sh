#!/bin/bash
# Funciones HTTP / Servidores Web (Fedora)

cargar_dependencias() {
    echo "Preparando dependencias del sistema..."
    if ! dnf install -y curl net-tools firewalld psmisc iproute; then
        echo "  Advertencia: Algunas dependencias no se instalaron." >&2
    fi
    systemctl enable firewalld --now 2>/dev/null
}

limpiar_entorno() {
    echo "Iniciando limpieza del entorno web..."
    systemctl stop httpd nginx tomcat 2>/dev/null
    local procs=("httpd" "nginx" "java")
    for p in "${procs[@]}"; do
        pids=$(pgrep -f "$p")
        [ -n "$pids" ] && kill -9 $pids 2>/dev/null
    done
    dnf remove -y httpd\* nginx\* tomcat\* 2>/dev/null
    dnf autoremove -y 2>/dev/null
    rm -rf /var/www/html/* /var/www/httpd_* /var/www/nginx_* 2>/dev/null
    rm -rf /usr/share/tomcat/webapps/ROOT/* 2>/dev/null
    echo -e "\e[32m[OK] Entorno limpio y listo.\e[0m"
}

pedir_puerto() {
    local puerto
    declare -A puertos_conocidos=(
        [20]="FTP" [21]="FTP" [22]="SSH" [25]="SMTP" [53]="DNS"
        [110]="POP3" [143]="IMAP" [445]="SMB/Samba" [2222]="SSH-Alt"
        [3306]="MySQL" [5432]="PostgreSQL" [3389]="RDP"
    )
    local bloqueados=(1 7 9 11 13 15 17 19 20 21 22 23 25 37 42 43 53 69 \
        77 79 110 111 113 115 117 118 119 123 135 137 139 143 161 177 179 \
        389 427 445 465 512 513 514 515 526 530 531 532 540 548 554 556 \
        563 587 601 636 989 990 993 995 1723 2049 2222 3306 3389 5432)
    while true; do
        read -p "  Puerto a utilizar (ej. 80, 8080, 8888): " puerto
        if [[ ! "$puerto" =~ ^[0-9]+$ ]] || [ "$puerto" -le 0 ] || [ "$puerto" -gt 65535 ]; then
            echo "  [Error] Puerto invalido. Rango permitido: 1-65535." >&2; continue
        fi
        if [[ " ${bloqueados[*]} " =~ " ${puerto} " ]]; then
            local desc=${puertos_conocidos[$puerto]:-"Reservado del sistema"}
            echo "  [Error] Puerto $puerto en uso por: $desc." >&2; continue
        fi
        if ss -tuln | grep -q ":$puerto "; then
            echo "  [Error] Puerto $puerto ocupado por otro proceso." >&2; continue
        fi
        break
    done
    echo "$puerto"
}

obtener_versiones() {
    local paquete=$1
    [ "$paquete" == "apache" ] && paquete="httpd"

    # Consultar versiones disponibles dinamicamente del repositorio
    mapfile -t versiones < <(
        dnf repoquery "$paquete" --available --queryformat "%{version}-%{release}" 2>/dev/null \
        | sort -Vu | tail -n 5
    )

    if [ ${#versiones[@]} -eq 0 ]; then
        mapfile -t versiones < <(
            dnf info "$paquete" 2>/dev/null \
            | awk '/^Version|^Release/{print $3}' \
            | paste - - | awk '{print $1"-"$2}' | head -3
        )
    fi

    if [ ${#versiones[@]} -eq 0 ]; then
        echo "  [Error] Sin versiones disponibles para $paquete." >&2; return 1
    fi

    if [ ${#versiones[@]} -eq 1 ]; then
        echo "" >&2
        echo "  Version unica disponible: ${versiones[0]}" >&2
        echo "  Se aplicara automaticamente." >&2
        echo "" >&2
        echo "${versiones[0]}"
        return
    fi

    # Etiquetar LTS (estable) y Latest (desarrollo)
    local total=${#versiones[@]}
    echo "" >&2
    echo "  Versiones disponibles para $paquete:" >&2
    local i=1
    for v in "${versiones[@]}"; do
        local etiqueta=""
        if [ $i -eq 1 ]; then
            etiqueta="[LTS - Estable]"
        elif [ $i -eq $total ]; then
            etiqueta="[Latest - Desarrollo]"
        else
            etiqueta="[Disponible]"
        fi
        echo "    $i) $v  $etiqueta" >&2
        ((i++))
    done
    echo "" >&2

    while true; do
        read -p "  Numero de version (1-${#versiones[@]}): " sel
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#versiones[@]}" ]; then
            echo "${versiones[$((sel - 1))]}"; break
        else
            echo "  [Error] Seleccion fuera de rango." >&2
        fi
    done
}

abrir_firewall() {
    local puerto=$1
    echo "  Abriendo puerto $puerto en firewalld..."
    firewall-cmd --permanent --add-port="$puerto"/tcp > /dev/null 2>&1
    for p in 80 443 8080 8888; do
        if [ "$p" -ne "$puerto" ]; then
            firewall-cmd --permanent --remove-port="$p"/tcp > /dev/null 2>&1
            firewall-cmd --permanent --remove-service=http  > /dev/null 2>&1
            firewall-cmd --permanent --remove-service=https > /dev/null 2>&1
        fi
    done
    firewall-cmd --reload > /dev/null 2>&1
    echo "  [OK] Firewall actualizado. Puerto activo: $puerto"
}

generar_index() {
    local ruta=$1 servicio=$2 version=$3 puerto=$4
    local ip
    ip=$(hostname -I | awk '{print $1}')
    cat <<HTMLEOF > "$ruta/index.html"
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
HTMLEOF
}

crear_usuario_web() {
    local usuario=$1 directorio=$2
    if ! id "$usuario" &>/dev/null; then
        useradd --system --no-create-home --shell /sbin/nologin "$usuario"
        echo "  Usuario '$usuario' creado para el servicio."
    fi
    chown -R "$usuario":"$usuario" "$directorio"
    chmod -R 750 "$directorio"
    echo "  Permisos aplicados en $directorio."
}

hardening_apache() {
    echo "  Aplicando configuracion de seguridad en Apache..."
    cat <<'EOF' > /etc/httpd/conf.d/security.conf
ServerTokens Prod
ServerSignature Off

<IfModule mod_headers.c>
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Referrer-Policy "no-referrer-when-downgrade"
    Header always unset X-Powered-By
</IfModule>

<Directory "/">
    <LimitExcept GET POST HEAD>
        Require all denied
    </LimitExcept>
</Directory>
EOF
    echo "  [OK] Seguridad aplicada en Apache."
}

hardening_nginx() {
    echo "  Aplicando configuracion de seguridad en Nginx..."
    mkdir -p /etc/nginx/conf.d
    cat <<'EOF' > /etc/nginx/conf.d/security-headers.conf
server_tokens off;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "no-referrer-when-downgrade" always;
EOF
    echo "  [OK] Seguridad aplicada en Nginx."
}

hardening_tomcat() {
    local webxml="/etc/tomcat/web.xml"
    echo "  Aplicando configuracion de seguridad en Tomcat..."
    sed -i 's/<Connector/<Connector server="WebServer"/g' /etc/tomcat/server.xml 2>/dev/null
    if [ -f "$webxml" ] && ! grep -q "HttpHeaderSecurityFilter" "$webxml"; then
        sed -i '/<\/web-app>/i\
    <filter><filter-name>httpHeaderSecurity<\/filter-name>\
    <filter-class>org.apache.catalina.filters.HttpHeaderSecurityFilter<\/filter-class>\
    <init-param><param-name>antiClickJackingEnabled<\/param-name><param-value>true<\/param-value><\/init-param>\
    <init-param><param-name>antiClickJackingOption<\/param-name><param-value>SAMEORIGIN<\/param-value><\/init-param>\
    <init-param><param-name>blockContentTypeSniffingEnabled<\/param-name><param-value>true<\/param-value><\/init-param>\
    <init-param><param-name>xssProtectionEnabled<\/param-name><param-value>true<\/param-value><\/init-param>\
    <\/filter>\
    <filter-mapping><filter-name>httpHeaderSecurity<\/filter-name>\
    <url-pattern>\/*<\/url-pattern><\/filter-mapping>' "$webxml" 2>/dev/null
    fi
    echo "  [OK] Seguridad aplicada en Tomcat."
}

# ============================================================
# INSTALACION DE SERVIDORES
# ============================================================

setup_apache() {
    local version=$1 puerto=$2
    echo ""; echo "  Configurando Apache en puerto $puerto..."
    if ! dnf install -y httpd; then
        echo "  [Error] No se pudo instalar httpd." >&2; return 1
    fi
    local dir_web="/var/www/httpd_$puerto"
    mkdir -p "$dir_web"
    sed -i "s/^Listen .*/Listen $puerto/" /etc/httpd/conf/httpd.conf
    sed -i "s/^Listen 443/#Listen 443/" /etc/httpd/conf/httpd.conf 2>/dev/null
    cat <<EOF > /etc/httpd/conf.d/vhost.conf
<VirtualHost *:$puerto>
    ServerAdmin admin@localhost
    DocumentRoot $dir_web
    ErrorLog /var/log/httpd/error.log
    CustomLog /var/log/httpd/access.log combined
</VirtualHost>
EOF
    hardening_apache
    generar_index "$dir_web" "Apache (httpd)" "$version" "$puerto"
    crear_usuario_web "apache" "$dir_web"
    if command -v semanage &>/dev/null; then
        semanage port -a -t http_port_t -p tcp "$puerto" 2>/dev/null || \
        semanage port -m -t http_port_t -p tcp "$puerto" 2>/dev/null
    fi
    abrir_firewall "$puerto"
    systemctl enable httpd --now
    if ! systemctl restart httpd; then
        echo "  [Error] Apache no pudo iniciar. Revisa: journalctl -xe -u httpd" >&2; return 1
    fi
    echo ""; echo -e "  \e[32m[OK] Apache listo en puerto $puerto.\e[0m"
    echo "       Directorio : $dir_web"
    echo "       Prueba con : curl -I http://localhost:$puerto"
}

setup_nginx() {
    local version=$1 puerto=$2
    echo ""; echo "  Configurando Nginx en puerto $puerto..."
    if ! dnf install -y nginx; then
        echo "  [Error] No se pudo instalar nginx." >&2; return 1
    fi
    local dir_web="/var/www/nginx_$puerto"
    mkdir -p "$dir_web"
    mkdir -p /etc/nginx/conf.d
    sed -i '/^\s*server\s*{/,/^\s*}/{ s/^/#DISABLED# / }' /etc/nginx/nginx.conf 2>/dev/null
    hardening_nginx
    cat <<EOF > /etc/nginx/conf.d/vhost_$puerto.conf
server {
    listen $puerto;
    root $dir_web;
    index index.html;
    server_name _;

    server_tokens off;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;

    if (\$request_method !~ ^(GET|POST|HEAD)$) {
        return 405;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    generar_index "$dir_web" "Nginx" "$version" "$puerto"
    crear_usuario_web "nginx" "$dir_web"
    if command -v semanage &>/dev/null; then
        semanage port -a -t http_port_t -p tcp "$puerto" 2>/dev/null || \
        semanage port -m -t http_port_t -p tcp "$puerto" 2>/dev/null
    fi
    abrir_firewall "$puerto"
    systemctl enable nginx --now
    if ! systemctl restart nginx; then
        echo "  [Error] Nginx no pudo iniciar. Revisa: journalctl -xe -u nginx" >&2
        nginx -t 2>&1; return 1
    fi
    echo ""; echo -e "  \e[32m[OK] Nginx listo en puerto $puerto.\e[0m"
    echo "       Directorio : $dir_web"
    echo "       Prueba con : curl -I http://localhost:$puerto"
}

setup_tomcat() {
    local version=$1 puerto=$2
    echo ""; echo "  Configurando Tomcat en puerto $puerto..."
    local java_pkg
    if dnf list available java-21-openjdk-headless &>/dev/null 2>&1; then
        java_pkg="java-21-openjdk-headless"
    elif dnf list available java-17-openjdk-headless &>/dev/null 2>&1; then
        java_pkg="java-17-openjdk-headless"
    else
        java_pkg=$(dnf repoquery "java-*-openjdk-headless" --available --queryformat "%{name}" 2>/dev/null | sort -V | tail -1)
    fi
    echo "  Java detectado: ${java_pkg:-java-openjdk}"
    if ! dnf install -y tomcat tomcat-webapps ${java_pkg:-java-latest-openjdk-headless}; then
        echo "  [Error] No se pudo instalar Tomcat." >&2; return 1
    fi
    sed -i "s/port=\"8080\"/port=\"$puerto\"/g" /etc/tomcat/server.xml
    hardening_tomcat
    mkdir -p /usr/share/tomcat/webapps/ROOT
    generar_index "/usr/share/tomcat/webapps/ROOT" "Tomcat" "$version" "$puerto"
    crear_usuario_web "tomcat" "/usr/share/tomcat/webapps"
    if command -v semanage &>/dev/null; then
        semanage port -a -t http_port_t -p tcp "$puerto" 2>/dev/null || \
        semanage port -m -t http_port_t -p tcp "$puerto" 2>/dev/null
    fi
    abrir_firewall "$puerto"
    systemctl enable tomcat --now
    if ! systemctl restart tomcat; then
        echo "  [Error] Tomcat no pudo iniciar. Revisa: journalctl -xe -u tomcat" >&2; return 1
    fi
    echo ""; echo -e "  \e[32m[OK] Tomcat listo en puerto $puerto.\e[0m"
    echo "       Prueba con : curl -I http://localhost:$puerto"
}

# ============================================================
# VERIFICAR / DESINSTALAR / ACTUALIZAR / REINICIAR
# ============================================================

estado_servicio() {
    local servicio=$1 puerto=$2
    echo ""
    echo "  ----[ $servicio : puerto $puerto ]----"
    if systemctl is-active --quiet "$servicio" 2>/dev/null; then
        echo -e "  \e[32m[OK] $servicio esta ACTIVO\e[0m"
    else
        echo -e "  \e[31m[!!] $servicio esta INACTIVO\e[0m"
        echo "       Revisa: journalctl -xe -u $servicio"
    fi
    if ss -tuln | grep -q ":$puerto "; then
        echo -e "  \e[32m[OK] Puerto $puerto escuchando\e[0m"
    else
        echo -e "  \e[33m[??] Puerto $puerto no detectado aun\e[0m"
    fi
    echo "  Encabezados HTTP:"
    curl -sI "http://localhost:$puerto" 2>/dev/null \
        | grep -E "^HTTP|^Server:|^X-Frame|^X-Content|^X-XSS" \
        | sed 's/^/       /' \
        || echo "       (Servicio iniciando, reintenta en unos segundos)"
    echo "  ------------------------------------------"
}

quitar_servidor() {
    echo ""; echo "  === Desinstalar servidor ==="
    echo "  1) Apache (httpd)   2) Nginx   3) Tomcat"; echo ""
    local op
    read -p "  Servidor a desinstalar (1-3): " op
    local pkg servicio
    case "$op" in
        1) pkg="httpd";  servicio="httpd" ;;
        2) pkg="nginx";  servicio="nginx" ;;
        3) pkg="tomcat"; servicio="tomcat" ;;
        *) echo "  [Error] Opcion no valida." >&2; return ;;
    esac
    if ! rpm -q "$pkg" > /dev/null 2>&1; then
        echo "  $pkg no esta instalado."; return
    fi
    read -p "  ¿Confirmar desinstalacion de $pkg? (s/N): " conf
    [[ ! "$conf" =~ ^[sS]$ ]] && { echo "  Operacion cancelada."; return; }
    systemctl stop "$servicio" 2>/dev/null
    pkill -f "$pkg" 2>/dev/null
    dnf remove -y "$pkg"\* 2>/dev/null
    dnf autoremove -y 2>/dev/null
    rm -rf /var/www/"${pkg}"_* /var/www/httpd_* 2>/dev/null
    echo -e "  \e[32m[OK] $pkg desinstalado.\e[0m"
}

actualizar_servidor() {
    echo ""; echo "  === Cambiar version de servidor ==="
    echo "  1) Apache (httpd)   2) Nginx   3) Tomcat"; echo ""
    local op
    read -p "  Servidor a actualizar (1-3): " op
    local pkg servicio nombre
    case "$op" in
        1) pkg="httpd";  servicio="httpd";  nombre="Apache (httpd)" ;;
        2) pkg="nginx";  servicio="nginx";  nombre="Nginx" ;;
        3) pkg="tomcat"; servicio="tomcat"; nombre="Tomcat" ;;
        *) echo "  [Error] Opcion no valida." >&2; return ;;
    esac
    local version_actual
    version_actual=$(rpm -q "$pkg" --queryformat "%{version}-%{release}" 2>/dev/null)
    if [ -z "$version_actual" ]; then
        echo "  $nombre no esta instalado. Usa primero la opcion Instalar."; return
    fi
    echo "  Version actual: $version_actual"; echo ""
    local nueva_ver
    nueva_ver=$(obtener_versiones "$pkg")
    [ $? -ne 0 ] || [ -z "$nueva_ver" ] && return
    if [ "$nueva_ver" == "$version_actual" ]; then
        echo "  Ya tienes esa version instalada."; return
    fi
    local puerto
    puerto=$(pedir_puerto)
    read -p "  ¿Confirmar cambio a $nueva_ver en puerto $puerto? (s/N): " conf
    [[ ! "$conf" =~ ^[sS]$ ]] && { echo "  Operacion cancelada."; return; }
    systemctl stop "$servicio" 2>/dev/null
    dnf remove -y "$pkg"\* 2>/dev/null
    dnf autoremove -y 2>/dev/null
    rm -rf /var/www/"${pkg}"_* /var/www/httpd_* 2>/dev/null
    case "$servicio" in
        httpd)  setup_apache "$nueva_ver" "$puerto"; estado_servicio "httpd"  "$puerto" ;;
        nginx)  setup_nginx  "$nueva_ver" "$puerto"; estado_servicio "nginx"  "$puerto" ;;
        tomcat) setup_tomcat "$nueva_ver" "$puerto"; estado_servicio "tomcat" "$puerto" ;;
    esac
}

reiniciar_servidor() {
    echo ""; echo "  === Levantar / Reiniciar servicio ==="
    local activos=()
    rpm -q httpd  > /dev/null 2>&1 && activos+=("1) Apache (httpd)")
    rpm -q nginx  > /dev/null 2>&1 && activos+=("2) Nginx")
    rpm -q tomcat > /dev/null 2>&1 && activos+=("3) Tomcat")
    if [ ${#activos[@]} -eq 0 ]; then
        echo "  No hay servidores instalados."; return
    fi
    echo "  Servidores detectados:"; echo ""
    for s in "${activos[@]}"; do echo "    $s"; done
    echo ""
    local op
    read -p "  Selecciona (1-3): " op
    local servicio nombre
    case "$op" in
        1) servicio="httpd";  nombre="Apache (httpd)" ;;
        2) servicio="nginx";  nombre="Nginx" ;;
        3) servicio="tomcat"; nombre="Tomcat" ;;
        *) echo "  [Error] Opcion no valida." >&2; return ;;
    esac
    local puerto
    read -p "  Puerto para $nombre: " puerto
    [[ ! "$puerto" =~ ^[0-9]+$ ]] && { echo "  [Error] Puerto no valido." >&2; return; }
    case "$servicio" in
        httpd)
            sed -i "s/^Listen .*/Listen $puerto/" /etc/httpd/conf/httpd.conf
            sed -i "s/VirtualHost \*:[0-9]*/VirtualHost *:$puerto/" /etc/httpd/conf.d/vhost.conf 2>/dev/null
            command -v semanage &>/dev/null && {
                semanage port -a -t http_port_t -p tcp "$puerto" 2>/dev/null || \
                semanage port -m -t http_port_t -p tcp "$puerto" 2>/dev/null
            } ;;
        nginx)
            local vhost
            vhost=$(ls /etc/nginx/conf.d/vhost_*.conf 2>/dev/null | head -1)
            [ -n "$vhost" ] && {
                sed -i "s/listen [0-9]*/listen $puerto/" "$vhost"
                mv "$vhost" "/etc/nginx/conf.d/vhost_$puerto.conf" 2>/dev/null
            }
            command -v semanage &>/dev/null && {
                semanage port -a -t http_port_t -p tcp "$puerto" 2>/dev/null || \
                semanage port -m -t http_port_t -p tcp "$puerto" 2>/dev/null
            } ;;
        tomcat)
            sed -i "s/port=\"[0-9]*\"/port=\"$puerto\"/" /etc/tomcat/server.xml 2>/dev/null
            command -v semanage &>/dev/null && {
                semanage port -a -t http_port_t -p tcp "$puerto" 2>/dev/null || \
                semanage port -m -t http_port_t -p tcp "$puerto" 2>/dev/null
            } ;;
    esac
    firewall-cmd --permanent --add-port="$puerto"/tcp > /dev/null 2>&1
    firewall-cmd --reload > /dev/null 2>&1
    systemctl enable "$servicio" --now 2>/dev/null
    if systemctl restart "$servicio"; then
        echo -e "  \e[32m[OK] $nombre activo en puerto $puerto.\e[0m"
        echo "  Accede en: http://$(hostname -I | awk '{print $1}'):$puerto"
        estado_servicio "$servicio" "$puerto"
    else
        echo -e "  \e[31m[!!] No se pudo levantar $nombre.\e[0m"
        echo "       Revisa: journalctl -xe -u $servicio"
    fi
}

flujo_instalar() {
    local servicio=$1 nombre=$2
    echo ""; echo "  === Instalacion: $nombre ==="
    cargar_dependencias
    local pkg="$servicio"
    [ "$servicio" == "apache" ] && pkg="httpd"
    if rpm -q "$pkg" > /dev/null 2>&1; then
        local ver_actual
        ver_actual=$(rpm -q "$pkg" --queryformat "%{version}-%{release}")
        echo "  $nombre ya se encuentra instalado (version: $ver_actual)."
        echo ""
        echo "  1) Reinstalar con otra version"
        echo "  2) Cancelar"
        echo ""
        local op
        read -p "  Opcion: " op
        [ "$op" == "1" ] && actualizar_servidor || echo "  Operacion cancelada."
        return
    fi
    local version
    version=$(obtener_versiones "$servicio")
    [ $? -ne 0 ] || [ -z "$version" ] && { echo "  [Error] No se obtuvo version. Abortando." >&2; return 1; }
    echo "  Version seleccionada: $version"; echo ""
    local puerto
    puerto=$(pedir_puerto)
    echo "  Puerto seleccionado : $puerto"; echo ""
    read -p "  ¿Iniciar instalacion de $nombre en puerto $puerto? (s/N): " ok
    [[ ! "$ok" =~ ^[sS]$ ]] && { echo "  Instalacion cancelada."; return 0; }
    case "$servicio" in
        apache) setup_apache "$version" "$puerto"; estado_servicio "httpd"  "$puerto" ;;
        nginx)  setup_nginx  "$version" "$puerto"; estado_servicio "nginx"  "$puerto" ;;
        tomcat) setup_tomcat "$version" "$puerto"; estado_servicio "tomcat" "$puerto" ;;
    esac
}

flujo_verificar() {
    echo ""; echo "  === Verificar servicio ==="
    echo "  1) Apache (httpd)   2) Nginx   3) Tomcat"; echo ""
    local op
    read -p "  Selecciona (1-3): " op
    local servicio
    case "$op" in
        1) servicio="httpd"  ;;
        2) servicio="nginx"  ;;
        3) servicio="tomcat" ;;
        *) echo "  [Error] Opcion no valida." >&2; return ;;
    esac
    local puerto
    read -p "  Puerto del servicio: " puerto
    [[ ! "$puerto" =~ ^[0-9]+$ ]] && { echo "  [Error] Puerto no valido." >&2; return; }
    estado_servicio "$servicio" "$puerto"
}
