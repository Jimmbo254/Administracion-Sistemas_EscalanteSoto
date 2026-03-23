#!/bin/bash

FTP_SERVER="127.0.0.1"
FTP_USER="repositorio"
FTP_PASS="Hola1234."
FTP_BASE="repositorio/Linux"

RESUMEN_INSTALACIONES=()
SERVICIOS_VERIFICAR=()

main() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "Ejecuta este script como root o con sudo."
        exit 1
    fi

    while true; do
        echo ""
        echo "========= ORQUESTADOR HTTP — FEDORA ========="
        echo "1) Apache (httpd)"
        echo "2) Nginx"
        echo "3) Tomcat"
        echo "4) vsftpd (FTP)"
        echo "5) Ver resumen de instalaciones"
        echo "6) Preparar repositorio FTP local"
        echo "7) Purgar todo"
        echo "0) Salir"
        echo "============================================="
        read -p "Opcion: " opcion < /dev/tty

        case "$opcion" in
            0) verificar_resumen; echo "Saliendo..."; break ;;
            5) verificar_resumen; continue ;;
            6) preparar_repositorio_ftp; continue ;;
            7) purgar_todo; continue ;;
            1|2|3|4) ;;
            *) echo "Opcion invalida."; continue ;;
        esac

        echo ""
        echo "Origen de instalacion:"
        echo "1) WEB (repositorio dnf)"
        echo "2) FTP (repositorio privado)"
        echo "0) Regresar"
        read -p "Selecciona origen: " origen < /dev/tty
        [[ "$origen" == "0" ]] && continue
        [[ "$origen" == "2" ]] && web_ftp="FTP" || web_ftp="WEB"

        ssl=$(preguntar_ssl)
        [[ "$ssl" == "REGRESAR" ]] && continue

        archivo=""
        if [[ "$web_ftp" == "FTP" ]]; then
            case "$opcion" in
                1) servicio_ftp="Apache" ;;
                2) servicio_ftp="Nginx"  ;;
                3) servicio_ftp="Tomcat" ;;
                4) servicio_ftp="vsftpd" ;;
            esac
            archivo=$(listar_versiones_ftp "$servicio_ftp")
            if [[ "$archivo" == "INVALIDO" || "$archivo" == "REGRESAR" ]]; then
                echo "Operacion cancelada."; continue
            fi
        fi

        case "$opcion" in
            1) instalar_apache  "$archivo" "$web_ftp" "$ssl" ;;
            2) instalar_nginx   "$archivo" "$web_ftp" "$ssl" ;;
            3) instalar_tomcat  "$archivo" "$web_ftp" "$ssl" ;;
            4) instalar_vsftpd  "$archivo" "$web_ftp" "$ssl" ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────
# PURGAR TODO
# ─────────────────────────────────────────────────────────────
purgar_todo() {
    echo "" > /dev/tty
    echo "=== Purgar todo ===" > /dev/tty
    echo "Se detendran y limpiaran: httpd, nginx, tomcat, vsftpd" > /dev/tty
    echo "Se borraran configs, certificados y puertos SELinux." > /dev/tty
    echo "" > /dev/tty
    read -p "Confirmas? [s/N]: " conf < /dev/tty
    [[ ! "$conf" =~ ^[sS]$ ]] && echo "Cancelado." > /dev/tty && return

    echo "" > /dev/tty
    echo "Deteniendo servicios..." > /dev/tty
    for svc in httpd nginx tomcat vsftpd; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc" > /dev/null 2>&1
            echo "  $svc detenido" > /dev/tty
        fi
        systemctl disable "$svc" > /dev/null 2>&1
    done

    echo "" > /dev/tty
    echo "Borrando configuraciones..." > /dev/tty

    rm -f /etc/httpd/conf.d/reprobados_apache.conf
    rm -f /etc/httpd/conf.d/ssl.conf /etc/httpd/conf.d/ssl.conf.bak
    rm -f /etc/httpd/conf.d/welcome.conf
    sed -i 's/^#Listen 80$/Listen 80/'   /etc/httpd/conf/httpd.conf 2>/dev/null
    sed -i 's/^#Listen 443$/Listen 443/' /etc/httpd/conf/httpd.conf 2>/dev/null
    echo "  Configs Apache limpiadas" > /dev/tty

    rm -f /etc/nginx/conf.d/reprobados_nginx.conf
    echo "  Configs Nginx limpiadas" > /dev/tty

    rm -f /var/lib/tomcat/webapps/ROOT/WEB-INF/web.xml
    echo "  Configs Tomcat limpiadas" > /dev/tty

    echo "  Configs vsftpd listas" > /dev/tty

    echo "" > /dev/tty
    echo "Borrando certificados SSL..." > /dev/tty
    rm -rf /etc/ssl/apache /etc/ssl/nginx /etc/ssl/tomcat /etc/vsftpd/ssl
    echo "  Certificados eliminados" > /dev/tty

    echo "" > /dev/tty
    echo "Limpiando puertos SELinux no estandar..." > /dev/tty
    for puerto in $(semanage port -l 2>/dev/null | grep http_port_t | grep -oP '\b\d+\b' \
                    | grep -vE '^(80|443|8080|8443|8008|8009|9090)$'); do
        semanage port -d -t http_port_t -p tcp "$puerto" > /dev/null 2>&1 \
            && echo "  Puerto SELinux $puerto liberado" > /dev/tty
    done

    echo "" > /dev/tty
    echo "Limpiando reglas de firewall..." > /dev/tty
    if systemctl is-active --quiet firewalld; then
        for p in $(firewall-cmd --list-ports 2>/dev/null); do
            puerto_num="${p%/*}"
            if [[ ! "$puerto_num" =~ ^(80|443|8080|8443|22)$ ]]; then
                firewall-cmd --permanent --remove-port="$p" > /dev/null 2>&1
                echo "  Puerto firewall $p removido" > /dev/tty
            fi
        done
        firewall-cmd --reload > /dev/null 2>&1
        echo "  Firewall recargado" > /dev/tty
    else
        echo "  firewalld no activo, se omite" > /dev/tty
    fi

    RESUMEN_INSTALACIONES=()
    SERVICIOS_VERIFICAR=()
    echo "" > /dev/tty
    echo "Purga completa. Puedes volver a instalar desde cero." > /dev/tty
    echo "" > /dev/tty
}

# ─────────────────────────────────────────────────────────────
# PEDIR PUERTO
# ─────────────────────────────────────────────────────────────
pedir_puerto() {
    local nombre=$1 default_http=$2 default_https=$3

    local puerto_http
    while true; do
        read -p "  Puerto HTTP para $nombre [Enter = $default_http]: " puerto_http < /dev/tty
        [[ -z "$puerto_http" ]] && puerto_http=$default_http
        if [[ "$puerto_http" =~ ^[0-9]+$ ]] && \
           [ "$puerto_http" -ge 1 ] && [ "$puerto_http" -le 65535 ]; then
            break
        fi
        echo "  Puerto invalido. Ingresa un numero entre 1 y 65535." > /dev/tty
    done

    local puerto_https
    while true; do
        read -p "  Puerto HTTPS para $nombre [Enter = $default_https]: " puerto_https < /dev/tty
        [[ -z "$puerto_https" ]] && puerto_https=$default_https
        if [[ "$puerto_https" =~ ^[0-9]+$ ]] && \
           [ "$puerto_https" -ge 1 ] && [ "$puerto_https" -le 65535 ]; then
            if [ "$puerto_https" -eq "$puerto_http" ]; then
                echo "  El puerto HTTPS no puede ser igual al HTTP." > /dev/tty
                continue
            fi
            break
        fi
        echo "  Puerto invalido. Ingresa un numero entre 1 y 65535." > /dev/tty
    done

    for p in "$puerto_http" "$puerto_https"; do
        if ss -tlnp | grep -q ":$p "; then
            echo "  Advertencia: el puerto $p ya esta en uso." > /dev/tty
        fi
    done

    echo "$puerto_http $puerto_https"
}

# ─────────────────────────────────────────────────────────────
# NAVEGACIÓN FTP
# ─────────────────────────────────────────────────────────────
listar_versiones_ftp() {
    local servicio=$1
    echo "" > /dev/tty
    echo "Buscando instaladores de $servicio en /$FTP_BASE/$servicio/ ..." > /dev/tty

    mapfile -t versiones < <(
        curl -s -l --insecure -u "$FTP_USER:$FTP_PASS" \
            "ftps://$FTP_SERVER/$FTP_BASE/$servicio/" 2>/dev/null \
        | grep -v '\.sha256$' | grep -v '\.md5$'
    )
    if [ ${#versiones[@]} -eq 0 ]; then
        mapfile -t versiones < <(
            curl -s -l -u "$FTP_USER:$FTP_PASS" \
                "ftp://$FTP_SERVER/$FTP_BASE/$servicio/" 2>/dev/null \
            | grep -v '\.sha256$' | grep -v '\.md5$'
        )
    fi

    if [ ${#versiones[@]} -eq 0 ]; then
        echo "No se encontraron versiones para $servicio." > /dev/tty
        echo "Verifica: /srv/ftp/autenticados/$FTP_USER/$FTP_BASE/$servicio/" > /dev/tty
        echo "INVALIDO"; return 1
    fi

    echo "Versiones disponibles:" > /dev/tty
    for i in "${!versiones[@]}"; do
        echo "$((i + 1))) ${versiones[$i]}" > /dev/tty
    done
    echo "0) Regresar" > /dev/tty

    local sel_ver
    read -p "Selecciona la version: " sel_ver < /dev/tty

    if [[ "$sel_ver" == "0" ]]; then
        echo "REGRESAR"
    elif [[ "$sel_ver" =~ ^[0-9]+$ ]] && \
         [ "$sel_ver" -ge 1 ] && [ "$sel_ver" -le "${#versiones[@]}" ]; then
        echo "${versiones[$((sel_ver - 1))]}"
    else
        echo "INVALIDO"
    fi
}

# ─────────────────────────────────────────────────────────────
# DESCARGA Y VALIDACIÓN DE INTEGRIDAD
# ─────────────────────────────────────────────────────────────
descargar_y_validar_hash() {
    local servicio=$1 archivo=$2
    local ruta_ftps="ftps://$FTP_SERVER/$FTP_BASE/$servicio/"
    local ruta_ftp="ftp://$FTP_SERVER/$FTP_BASE/$servicio/"

    echo "Descargando $archivo desde FTP..." > /dev/tty
    cd /tmp || exit 1

    curl -s --insecure -u "$FTP_USER:$FTP_PASS" -O "${ruta_ftps}${archivo}" 2>/dev/null
    if [[ ! -s "$archivo" ]]; then
        curl -s -u "$FTP_USER:$FTP_PASS" -O "${ruta_ftp}${archivo}" 2>/dev/null
    fi
    if [[ ! -f "$archivo" ]]; then
        echo "Error: No se pudo descargar $archivo." > /dev/tty; return 1
    fi

    curl -s --insecure -u "$FTP_USER:$FTP_PASS" -O "${ruta_ftps}${archivo}.sha256" 2>/dev/null
    if [[ ! -s "${archivo}.sha256" ]]; then
        curl -s -u "$FTP_USER:$FTP_PASS" -O "${ruta_ftp}${archivo}.sha256" 2>/dev/null
    fi
    if [[ -s "${archivo}.sha256" ]]; then
        local hash_remoto hash_local
        hash_remoto=$(awk '{print $1}' "${archivo}.sha256")
        hash_local=$(sha256sum "$archivo" | awk '{print $1}')
        if [ "$hash_remoto" = "$hash_local" ]; then
            echo "Integridad SHA256 verificada." > /dev/tty
            rm -f "${archivo}.sha256"; return 0
        else
            echo "Error SHA256: el hash no coincide. Abortando." > /dev/tty
            rm -f "$archivo" "${archivo}.sha256"; return 1
        fi
    fi

    rm -f "${archivo}.sha256"
    curl -s --insecure -u "$FTP_USER:$FTP_PASS" -O "${ruta_ftps}${archivo}.md5" 2>/dev/null
    if [[ ! -s "${archivo}.md5" ]]; then
        curl -s -u "$FTP_USER:$FTP_PASS" -O "${ruta_ftp}${archivo}.md5" 2>/dev/null
    fi
    if [[ -s "${archivo}.md5" ]]; then
        local hash_remoto hash_local
        hash_remoto=$(awk '{print $1}' "${archivo}.md5")
        hash_local=$(md5sum "$archivo" | awk '{print $1}')
        if [ "$hash_remoto" = "$hash_local" ]; then
            echo "Integridad MD5 verificada." > /dev/tty
            rm -f "${archivo}.md5"; return 0
        else
            echo "Error MD5: el hash no coincide. Abortando." > /dev/tty
            rm -f "$archivo" "${archivo}.md5"; return 1
        fi
    fi

    rm -f "${archivo}.md5"
    echo "Sin archivo de hash. Se omite validacion." > /dev/tty
    return 0
}

# ─────────────────────────────────────────────────────────────
# INSTALACIÓN DESDE PAQUETE LOCAL
# ─────────────────────────────────────────────────────────────
instalar_paquete_local() {
    local archivo="/tmp/$1" servicio="$2"
    echo "Instalando $1 ..." > /dev/tty
    case "$archivo" in
        *.rpm) dnf install -y "$archivo" > /dev/null 2>&1 ;;
        *.tar.gz|*.tgz)
            mkdir -p "/opt/$servicio"
            local niveles
            niveles=$(tar -tzf "$archivo" 2>/dev/null | awk -F'/' '{print NF-1}' | sort -n | head -1)
            if [ "$niveles" -ge 1 ]; then
                tar -xzf "$archivo" -C "/opt/$servicio" --strip-components=1
            else
                tar -xzf "$archivo" -C "/opt/$servicio"
            fi
            echo "Extraido en /opt/$servicio" > /dev/tty ;;
        *.tar.bz2)
            mkdir -p "/opt/$servicio"
            local niveles
            niveles=$(tar -tjf "$archivo" 2>/dev/null | awk -F'/' '{print NF-1}' | sort -n | head -1)
            if [ "$niveles" -ge 1 ]; then
                tar -xjf "$archivo" -C "/opt/$servicio" --strip-components=1
            else
                tar -xjf "$archivo" -C "/opt/$servicio"
            fi
            echo "Extraido en /opt/$servicio" > /dev/tty ;;
        *.zip)
            mkdir -p "/opt/$servicio"
            unzip -q "$archivo" -d "/opt/$servicio"
            echo "Extraido en /opt/$servicio" > /dev/tty ;;
        *)
            echo "Error: Formato no reconocido: $archivo" > /dev/tty; return 1 ;;
    esac
    return 0
}

# ─────────────────────────────────────────────────────────────
# PREGUNTA SSL
# ─────────────────────────────────────────────────────────────
preguntar_ssl() {
    while true; do
        local resp
        read -p "Activar SSL? [S/N] (0 para regresar): " resp < /dev/tty
        [[ "$resp" =~ ^[sS]$ ]] && echo "S" && return
        [[ "$resp" =~ ^[nN]$ ]] && echo "N" && return
        [[ "$resp" == "0" ]]    && echo "REGRESAR" && return
        echo "Respuesta invalida." > /dev/tty
    done
}

# ─────────────────────────────────────────────────────────────
# CERTIFICADO AUTOFIRMADO
# ─────────────────────────────────────────────────────────────
generar_ssl() {
    local servicio=$1
    local cert_dir="/etc/ssl/$servicio"
    mkdir -p "$cert_dir"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$cert_dir/server.key" \
        -out    "$cert_dir/server.crt" \
        -subj "/C=MX/ST=Sinaloa/L=Los Mochis/O=Reprobados/CN=www.reprobados.com" \
        > /dev/null 2>&1
    echo "$cert_dir"
}

# ─────────────────────────────────────────────────────────────
# PÁGINA HTML — texto simple sin diseño
# ─────────────────────────────────────────────────────────────
crear_index() {
    local servidor=$1 ssl_status=$2 puerto=$3 docroot=$4
    local proto="HTTP"
    [[ "$ssl_status" == "S" ]] && proto="HTTPS"
    local ip
    ip=$(hostname -I | awk '{print $1}')
    mkdir -p "$docroot"
    cat > "$docroot/index.html" <<EOF
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<title>$servidor</title>
</head>
<body>
  <h2>$servidor</h2>
  <p>Protocolo: $proto</p>
  <p>IP: $ip</p>
  <p>Puerto: $puerto</p>
  <p>Host: www.reprobados.com</p>
</body>
</html>
EOF
}

# ─────────────────────────────────────────────────────────────
# FIREWALL
# ─────────────────────────────────────────────────────────────
abrir_puerto_firewall() {
    local puerto=$1 proto=${2:-tcp}
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="$puerto/$proto" > /dev/null 2>&1
    fi
}

recargar_firewall() {
    systemctl is-active --quiet firewalld && firewall-cmd --reload > /dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────
# APACHE
# ─────────────────────────────────────────────────────────────
instalar_apache() {
    local archivo=$1 web_ftp=$2 ssl=$3
    local docroot="/var/www/apache"
    local conf_dir="/etc/httpd/conf.d"

    echo "" > /dev/tty
    echo "Configuracion de puertos para Apache:" > /dev/tty
    read puerto_http puerto_https <<< $(pedir_puerto "Apache" 80 443)

    if [[ "$web_ftp" == "FTP" ]]; then
        descargar_y_validar_hash "Apache" "$archivo" || return 1
        instalar_paquete_local "$archivo" "httpd" || return 1
    else
        echo "Instalando Apache desde DNF..." > /dev/tty
        dnf install -y httpd mod_ssl > /dev/null
    fi

    mkdir -p "$conf_dir"
    local puerto_display=$puerto_http
    [[ "$ssl" == "S" ]] && puerto_display=$puerto_https
    crear_index "Apache (httpd)" "$ssl" "$puerto_display" "$docroot"
    chcon -R -t httpd_sys_content_t "$docroot" > /dev/null 2>&1

    rm -f "$conf_dir"/reprobados_apache.conf
    rm -f "$conf_dir"/ssl.conf "$conf_dir"/ssl.conf.bak "$conf_dir"/welcome.conf
    sed -i 's/^Listen 80$/#Listen 80/'   /etc/httpd/conf/httpd.conf 2>/dev/null
    sed -i 's/^Listen 443$/#Listen 443/' /etc/httpd/conf/httpd.conf 2>/dev/null

    if [[ "$ssl" == "S" ]]; then
        local dir; dir=$(generar_ssl "apache")
        cat > "$conf_dir/reprobados_apache.conf" <<EOF
Listen $puerto_http
Listen $puerto_https

<VirtualHost *:$puerto_http>
    ServerName www.reprobados.com
    Redirect permanent / https://www.reprobados.com:$puerto_https/
</VirtualHost>

<VirtualHost *:$puerto_https>
    ServerName www.reprobados.com
    DocumentRoot $docroot
    SSLEngine on
    SSLCertificateFile    $dir/server.crt
    SSLCertificateKeyFile $dir/server.key
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
</VirtualHost>
EOF
        abrir_puerto_firewall "$puerto_http"
        abrir_puerto_firewall "$puerto_https"
        SERVICIOS_VERIFICAR+=("Apache|httpd|$puerto_http|http")
        SERVICIOS_VERIFICAR+=("Apache-SSL|httpd|$puerto_https|https")
    else
        cat > "$conf_dir/reprobados_apache.conf" <<EOF
Listen $puerto_http

<VirtualHost *:$puerto_http>
    ServerName www.reprobados.com
    DocumentRoot $docroot
</VirtualHost>
EOF
        abrir_puerto_firewall "$puerto_http"
        SERVICIOS_VERIFICAR+=("Apache|httpd|$puerto_http|http")
    fi

    setsebool -P httpd_can_network_connect 1 > /dev/null 2>&1
    semanage port -a -t http_port_t -p tcp "$puerto_http"  > /dev/null 2>&1
    semanage port -a -t http_port_t -p tcp "$puerto_https" > /dev/null 2>&1
    recargar_firewall
    systemctl enable --now httpd > /dev/null
    systemctl restart httpd

    RESUMEN_INSTALACIONES+=("Apache | SSL:$ssl | HTTP:$puerto_http  HTTPS:$puerto_https")
    echo "Apache instalado. Accede en http://127.0.0.1:$puerto_http" > /dev/tty
}

# ─────────────────────────────────────────────────────────────
# NGINX
# ─────────────────────────────────────────────────────────────
instalar_nginx() {
    local archivo=$1 web_ftp=$2 ssl=$3
    local docroot="/var/www/nginx"
    local conf_dir="/etc/nginx/conf.d"

    echo "" > /dev/tty
    echo "Configuracion de puertos para Nginx:" > /dev/tty
    read puerto_http puerto_https <<< $(pedir_puerto "Nginx" 8081 8444)

    if [[ "$web_ftp" == "FTP" ]]; then
        descargar_y_validar_hash "Nginx" "$archivo" || return 1
        instalar_paquete_local "$archivo" "nginx" || return 1
    else
        echo "Instalando Nginx desde DNF..." > /dev/tty
        dnf install -y nginx > /dev/null
    fi

    mkdir -p "$conf_dir"
    local puerto_display=$puerto_http
    [[ "$ssl" == "S" ]] && puerto_display=$puerto_https
    crear_index "Nginx" "$ssl" "$puerto_display" "$docroot"
    chcon -R -t httpd_sys_content_t "$docroot" > /dev/null 2>&1

    cat > /etc/nginx/nginx.conf <<'NGINXEOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;
events { worker_connections 1024; }
http {
    log_format main '$remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent';
    access_log /var/log/nginx/access.log main;
    sendfile on; tcp_nopush on; keepalive_timeout 65;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    include /etc/nginx/conf.d/*.conf;
}
NGINXEOF

    rm -f "$conf_dir"/*.conf
    if [[ "$ssl" == "S" ]]; then
        local dir; dir=$(generar_ssl "nginx")
        cat > "$conf_dir/reprobados_nginx.conf" <<EOF
server {
    listen $puerto_http;
    server_name www.reprobados.com;
    return 301 https://\$host:$puerto_https\$request_uri;
}
server {
    listen $puerto_https ssl;
    server_name www.reprobados.com;
    ssl_certificate     $dir/server.crt;
    ssl_certificate_key $dir/server.key;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    root  $docroot;
    index index.html;
}
EOF
        abrir_puerto_firewall "$puerto_http"
        abrir_puerto_firewall "$puerto_https"
        SERVICIOS_VERIFICAR+=("Nginx|nginx|$puerto_http|http")
        SERVICIOS_VERIFICAR+=("Nginx-SSL|nginx|$puerto_https|https")
    else
        cat > "$conf_dir/reprobados_nginx.conf" <<EOF
server {
    listen $puerto_http;
    server_name www.reprobados.com;
    root  $docroot;
    index index.html;
}
EOF
        abrir_puerto_firewall "$puerto_http"
        SERVICIOS_VERIFICAR+=("Nginx|nginx|$puerto_http|http")
    fi

    setsebool -P httpd_can_network_connect 1 > /dev/null 2>&1
    semanage port -a -t http_port_t -p tcp "$puerto_http"  > /dev/null 2>&1
    semanage port -a -t http_port_t -p tcp "$puerto_https" > /dev/null 2>&1
    recargar_firewall
    systemctl enable --now nginx > /dev/null
    systemctl restart nginx

    RESUMEN_INSTALACIONES+=("Nginx  | SSL:$ssl | HTTP:$puerto_http  HTTPS:$puerto_https")
    echo "Nginx instalado. Accede en http://127.0.0.1:$puerto_http" > /dev/tty
}

# ─────────────────────────────────────────────────────────────
# TOMCAT
# ─────────────────────────────────────────────────────────────
instalar_tomcat() {
    local archivo=$1 web_ftp=$2 ssl=$3

    echo "" > /dev/tty
    echo "Configuracion de puertos para Tomcat:" > /dev/tty
    read puerto_http puerto_https <<< $(pedir_puerto "Tomcat" 8080 8443)

    echo "Instalando Java y Tomcat..." > /dev/tty
    dnf install -y java-17-openjdk > /dev/null

    if [[ "$web_ftp" == "FTP" ]]; then
        descargar_y_validar_hash "Tomcat" "$archivo" || return 1
        instalar_paquete_local "$archivo" "tomcat" || return 1
    else
        dnf install -y tomcat > /dev/null
    fi

    local T_USER="tomcat"
    local docroot="/var/lib/tomcat/webapps/ROOT"
    local puerto_display=$puerto_http
    [[ "$ssl" == "S" ]] && puerto_display=$puerto_https
    crear_index "Tomcat" "$ssl" "$puerto_display" "$docroot"
    chown -R "$T_USER:$T_USER" "$docroot"

    if [[ "$ssl" == "S" ]]; then
        local dir; dir=$(generar_ssl "tomcat")
        local ks="/etc/ssl/tomcat/keystore.p12"
        openssl pkcs12 -export \
            -in "$dir/server.crt" -inkey "$dir/server.key" \
            -out "$ks" -name tomcat \
            -password pass:reprobados > /dev/null 2>&1
        chown "$T_USER:$T_USER" "$ks"

        cat > /etc/tomcat/server.xml <<EOF
<Server port="8005" shutdown="SHUTDOWN">
  <Service name="Catalina">
    <Connector port="$puerto_http" protocol="HTTP/1.1" connectionTimeout="20000" redirectPort="$puerto_https" />
    <Connector port="$puerto_https" protocol="org.apache.coyote.http11.Http11NioProtocol" maxThreads="150" SSLEnabled="true">
      <SSLHostConfig>
        <Certificate certificateKeystoreFile="$ks" type="RSA" certificateKeystorePassword="reprobados" />
      </SSLHostConfig>
    </Connector>
    <Engine name="Catalina" defaultHost="localhost">
      <Host name="localhost" appBase="webapps" unpackWARs="true" autoDeploy="true" />
    </Engine>
  </Service>
</Server>
EOF

        mkdir -p "$docroot/WEB-INF"
        cat > "$docroot/WEB-INF/web.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<web-app xmlns="https://jakarta.ee/xml/ns/jakartaee"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="https://jakarta.ee/xml/ns/jakartaee https://jakarta.ee/xml/ns/jakartaee/web-app_5_0.xsd"
         version="5.0">
  <filter>
    <filter-name>httpHeaderSecurity</filter-name>
    <filter-class>org.apache.catalina.filters.HttpHeaderSecurityFilter</filter-class>
    <init-param><param-name>hstsEnabled</param-name><param-value>true</param-value></init-param>
    <init-param><param-name>hstsMaxAgeSeconds</param-name><param-value>31536000</param-value></init-param>
    <init-param><param-name>hstsIncludeSubDomains</param-name><param-value>true</param-value></init-param>
  </filter>
  <filter-mapping>
    <filter-name>httpHeaderSecurity</filter-name>
    <url-pattern>/*</url-pattern>
  </filter-mapping>
  <security-constraint>
    <web-resource-collection>
      <web-resource-name>Forzar HTTPS</web-resource-name>
      <url-pattern>/*</url-pattern>
    </web-resource-collection>
    <user-data-constraint>
      <transport-guarantee>CONFIDENTIAL</transport-guarantee>
    </user-data-constraint>
  </security-constraint>
</web-app>
EOF
        chown -R "$T_USER:$T_USER" "$docroot/WEB-INF"
        abrir_puerto_firewall "$puerto_http"
        abrir_puerto_firewall "$puerto_https"
        SERVICIOS_VERIFICAR+=("Tomcat|tomcat|$puerto_http|http")
        SERVICIOS_VERIFICAR+=("Tomcat-SSL|tomcat|$puerto_https|https")
    else
        cat > /etc/tomcat/server.xml <<EOF
<Server port="8005" shutdown="SHUTDOWN">
  <Service name="Catalina">
    <Connector port="$puerto_http" protocol="HTTP/1.1" connectionTimeout="20000" />
    <Engine name="Catalina" defaultHost="localhost">
      <Host name="localhost" appBase="webapps" unpackWARs="true" autoDeploy="true" />
    </Engine>
  </Service>
</Server>
EOF
        abrir_puerto_firewall "$puerto_http"
        SERVICIOS_VERIFICAR+=("Tomcat|tomcat|$puerto_http|http")
    fi

    semanage port -a -t http_port_t -p tcp "$puerto_http"  > /dev/null 2>&1
    semanage port -a -t http_port_t -p tcp "$puerto_https" > /dev/null 2>&1
    recargar_firewall
    systemctl enable --now tomcat > /dev/null
    systemctl restart tomcat
    echo "Esperando que Tomcat levante (8s)..." > /dev/tty
    sleep 8

    RESUMEN_INSTALACIONES+=("Tomcat | SSL:$ssl | HTTP:$puerto_http  HTTPS:$puerto_https")
    echo "Tomcat instalado. Accede en http://127.0.0.1:$puerto_http" > /dev/tty
}

# ─────────────────────────────────────────────────────────────
# VSFTPD
# ─────────────────────────────────────────────────────────────
instalar_vsftpd() {
    local archivo=$1 web_ftp=$2 ssl=$3

    if [[ "$web_ftp" == "FTP" ]]; then
        descargar_y_validar_hash "vsftpd" "$archivo" || return 1
        instalar_paquete_local "$archivo" "vsftpd" || return 1
    else
        echo "Instalando vsftpd desde DNF..." > /dev/tty
        dnf install -y vsftpd openssl > /dev/null
    fi

    grep -q "/bin/bash" /etc/shells || echo /bin/bash >> /etc/shells
    mkdir -p /srv/ftp/{anon,autenticados,grupos/general,grupos/reprobados,grupos/recursadores}
    mkdir -p /etc/vsftpd/ssl

    if [[ "$ssl" == "S" ]]; then
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout /etc/vsftpd/ssl/vsftpd.key \
            -out    /etc/vsftpd/ssl/vsftpd.crt \
            -subj "/C=MX/ST=Sinaloa/L=Los Mochis/O=Reprobados/CN=www.reprobados.com" \
            > /dev/null 2>&1
    fi

    setsebool -P ftpd_full_access 1       > /dev/null 2>&1
    setsebool -P allow_ftpd_full_access 1 > /dev/null 2>&1

    cat > /etc/vsftpd/vsftpd.conf <<EOF
local_enable=YES
write_enable=YES
local_umask=002
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
listen=YES
listen_ipv6=NO
pam_service_name=vsftpd

user_sub_token=\$USER
chroot_local_user=YES
allow_writeable_chroot=YES
local_root=/srv/ftp/autenticados/\$USER

pasv_enable=YES
pasv_min_port=40000
pasv_max_port=50000
pasv_address=$FTP_SERVER
EOF

    if [[ "$ssl" == "S" ]]; then
        cat >> /etc/vsftpd/vsftpd.conf <<EOF

listen_port=990
implicit_ssl=YES
ssl_enable=YES
allow_anon_ssl=NO
force_local_data_ssl=YES
force_local_logins_ssl=YES
ssl_tlsv1=YES
ssl_sslv2=NO
ssl_sslv3=NO
require_ssl_reuse=NO
ssl_ciphers=HIGH
rsa_cert_file=/etc/vsftpd/ssl/vsftpd.crt
rsa_private_key_file=/etc/vsftpd/ssl/vsftpd.key
EOF
        abrir_puerto_firewall 990
        SERVICIOS_VERIFICAR+=("vsftpd-FTPS|vsftpd|990|ftps")
    else
        cat >> /etc/vsftpd/vsftpd.conf <<EOF

anonymous_enable=YES
anon_root=/srv/ftp/anon
anon_upload_enable=NO
anon_mkdir_write_enable=NO
anon_other_write_enable=NO
EOF
        abrir_puerto_firewall 21
        SERVICIOS_VERIFICAR+=("vsftpd|vsftpd|21|ftp")
    fi

    abrir_puerto_firewall 20
    abrir_puerto_firewall "40000-50000"
    recargar_firewall
    systemctl enable --now vsftpd > /dev/null
    systemctl restart vsftpd

    RESUMEN_INSTALACIONES+=("vsftpd | SSL:$ssl | FTP:21  FTPS:990")
    echo "vsftpd instalado correctamente." > /dev/tty
}

# ─────────────────────────────────────────────────────────────
# VERIFICACIÓN
# ─────────────────────────────────────────────────────────────
verificar_http() {
    local nombre=$1 servicio=$2 puerto=$3 proto=$4
    local estado="INACTIVO"
    systemctl is-active --quiet "$servicio" 2>/dev/null && estado="ACTIVO"
    local resp="N/A"
    if [[ "$proto" == "https" ]]; then
        resp=$(curl -sk --max-time 5 "https://127.0.0.1:$puerto" -o /dev/null -w "%{http_code}" 2>/dev/null)
    elif [[ "$proto" == "http" ]]; then
        resp=$(curl -s  --max-time 5 "http://127.0.0.1:$puerto"  -o /dev/null -w "%{http_code}" 2>/dev/null)
    fi
    echo "  [$nombre] Proceso: $estado | Puerto $puerto ($proto): HTTP $resp"
}

verificar_ftp() {
    local nombre=$1 servicio=$2 puerto=$3
    local estado="INACTIVO"
    systemctl is-active --quiet "$servicio" 2>/dev/null && estado="ACTIVO"
    local conexion="CERRADO"
    nc -z -w3 127.0.0.1 "$puerto" 2>/dev/null && conexion="ABIERTO"
    echo "  [$nombre] Proceso: $estado | Puerto $puerto (TCP): $conexion"
}

verificar_hsts() {
    local nombre=$1 puerto=$2
    local hsts
    hsts=$(curl -sk --max-time 5 -I "https://127.0.0.1:$puerto" 2>/dev/null \
           | grep -i "strict-transport-security" | tr -d '\r')
    if [[ -n "$hsts" ]]; then
        echo "  [$nombre] HSTS: OK ($hsts)"
    else
        echo "  [$nombre] HSTS: no encontrado"
    fi
}

verificar_resumen() {
    echo ""
    echo "========= RESUMEN DE SERVICIOS ========="

    if [ ${#RESUMEN_INSTALACIONES[@]} -eq 0 ]; then
        echo "  No se ha instalado ningun servicio en esta sesion."
    else
        echo ""
        echo "Servicios instalados en esta sesion:"
        for r in "${RESUMEN_INSTALACIONES[@]}"; do echo "  -> $r"; done
    fi

    echo ""
    echo "Verificacion activa de cada servicio:"
    if [ ${#SERVICIOS_VERIFICAR[@]} -eq 0 ]; then
        echo "  (sin servicios registrados aun)"
    else
        for entrada in "${SERVICIOS_VERIFICAR[@]}"; do
            IFS='|' read -r nombre unit puerto proto <<< "$entrada"
            case "$proto" in
                http|https)
                    verificar_http "$nombre" "$unit" "$puerto" "$proto"
                    [[ "$proto" == "https" ]] && verificar_hsts "$nombre" "$puerto"
                    ;;
                ftp|ftps) verificar_ftp "$nombre" "$unit" "$puerto" ;;
            esac
        done
    fi

    echo ""
    echo "Puertos activos en el sistema:"
    ss -tlnp | awk 'NR>1 {print "  " $4}' | sort -u
    echo "========================================="
    echo ""
}

# ─────────────────────────────────────────────────────────────
# PREPARAR REPOSITORIO FTP LOCAL
# ─────────────────────────────────────────────────────────────
preparar_repositorio_ftp() {
    local base="/srv/ftp/autenticados/repositorio/Linux"
    echo "" > /dev/tty
    echo "=== Preparando repositorio FTP local ===" > /dev/tty
    echo "Ruta base: $base" > /dev/tty

    mkdir -p "$base/Apache" "$base/Nginx" "$base/Tomcat" "$base/vsftpd"

    echo "" > /dev/tty; echo "Descargando RPMs con dnf download..." > /dev/tty
    echo "  Apache (httpd)..." > /dev/tty
    dnf download httpd mod_ssl --destdir "$base/Apache/" > /dev/null 2>&1
    echo "  Nginx..." > /dev/tty
    dnf download nginx --destdir "$base/Nginx/" > /dev/null 2>&1
    echo "  Tomcat + Java..." > /dev/tty
    dnf download tomcat java-17-openjdk --destdir "$base/Tomcat/" > /dev/null 2>&1
    if [ -z "$(ls $base/Tomcat/*.rpm 2>/dev/null)" ]; then
        dnf install -y tomcat java-17-openjdk --downloadonly --downloaddir="$base/Tomcat/" > /dev/null 2>&1
    fi
    if [ -z "$(ls $base/Tomcat/*.rpm 2>/dev/null)" ]; then
        find /var/cache/dnf -name "tomcat*.rpm" 2>/dev/null | head -5 | xargs -I{} cp {} "$base/Tomcat/" 2>/dev/null
        find /var/cache/dnf -name "java-17-openjdk-[0-9]*.rpm" 2>/dev/null | head -2 | xargs -I{} cp {} "$base/Tomcat/" 2>/dev/null
    fi
    echo "  vsftpd..." > /dev/tty
    dnf download vsftpd --destdir "$base/vsftpd/" > /dev/null 2>&1

    echo "" > /dev/tty; echo "Generando archivos SHA256..." > /dev/tty
    for servicio in Apache Nginx Tomcat vsftpd; do
        for f in "$base/$servicio/"*.rpm; do
            [[ -f "$f" ]] || continue
            sha256sum "$f" | awk '{print $1}' > "${f}.sha256"
            echo "  $(basename $f).sha256" > /dev/tty
        done
    done

    chown -R repositorio:repositorio /srv/ftp/autenticados/repositorio/ 2>/dev/null
    chmod -R 755 /srv/ftp/autenticados/repositorio/

    echo "" > /dev/tty
    echo "Repositorio FTP listo en $base" > /dev/tty
    echo "Conectate como: $FTP_USER en ftp://$FTP_SERVER" > /dev/tty
    echo "" > /dev/tty
    echo "Archivos disponibles:" > /dev/tty
    find "$base" -name "*.rpm" | sort | while read f; do echo "  $(basename $f)" > /dev/tty; done
    echo "=========================================" > /dev/tty
}

main
