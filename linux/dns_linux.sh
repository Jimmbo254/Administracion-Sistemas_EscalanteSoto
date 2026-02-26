#!/bin/bash
# dns_linux.sh — Servicio DNS linux

. "./funciones_linux.sh"

ZONES_DIR="/var/named"
NAMED_CONF="/etc/named.conf"
ZONES_CONF="/etc/named.rfc1912.zones"

# FUNCIONES DNS

verificar_setup() {
    echo "Verificando configuracion del servidor DNS..."

    # CAMBIO: limpiar lineas duplicadas o defaults antes de inyectar
    # evito que si se ejecuta instalar varias veces se duplique y BIND truene
    sed -i '/allow-query { any; };/d' "$NAMED_CONF"
    sed -i '/listen-on port 53 { any; };/d' "$NAMED_CONF"
    sed -i '/listen-on-v6 port 53 { none; };/d' "$NAMED_CONF"
    sed -i 's/listen-on port 53 { 127.0.0.1; };//g' "$NAMED_CONF"
    sed -i 's/listen-on-v6 port 53 { ::1; };//g' "$NAMED_CONF"
    sed -i 's/allow-query     { localhost; };//g' "$NAMED_CONF"

    # CAMBIO: inyectar configuracion para que escuche en cualquier IP
    sed -i '/^[[:space:]]*options[[:space:]]*{/a\
    allow-query { any; };\
    listen-on port 53 { any; };\
    listen-on-v6 port 53 { none; };' "$NAMED_CONF"
    # FIN CAMBIO
    
    if named-checkconf "$NAMED_CONF"; then
        echo "[OK] named.conf valido"
    else
        echo "[Error] named.conf invalido"
        exit 1
    fi

    if ! firewall-cmd --list-services | grep -qw dns; then
        firewall-cmd --add-service=dns --permanent &>/dev/null
        firewall-cmd --reload &>/dev/null
        echo "[OK] Servicio DNS agregado al firewall"
    fi

    systemctl restart named

    if systemctl is-active --quiet named; then
        echo -e "\e[32m[OK] Servicio named RUNNING.\e[0m"
    else
        echo -e "\e[31m[ERROR] named fallo al iniciar. Revisa: journalctl -xeu named\e[0m"
    fi

    # Apuntar sistema a BIND local ignorando DNS automaticos
    con_name=$(nmcli -t -f NAME con show --active | grep -v lo | head -1)
    nmcli con mod "$con_name" ipv4.ignore-auto-dns yes &>/dev/null
    nmcli con mod "$con_name" ipv4.dns "127.0.0.1" &>/dev/null
    nmcli con up "$con_name" &>/dev/null
    echo "[OK] Sistema apuntando a DNS local."
    read -p "Presione Enter..."
}

verificar_dns() {
    echo ""
    echo "=== Verificar instalacion DNS ==="
    if paquete_instalado "bind"; then
        echo "[OK] DNS service esta instalado"
    else
        echo "[Error] DNS service NO esta instalado"
    fi
    verificar_setup
    read -p "Presione Enter..."
}

instalar_dns() {
    echo ""
    echo "==== Instalando dependencias DNS ===="
    instalar_paquete "ipcalc"
    instalar_paquete "bind-utils"

    if ! paquete_instalado "bind"; then
        instalar_paquete "bind"
        if [[ $? -eq 0 ]]; then
            echo "[OK] bind instalado correctamente"
        else
            echo "[Error] Fallo al instalar bind"
            read -p "Presione Enter..."; return
        fi
    else
        echo "[OK] bind ya esta instalado"
    fi

    systemctl enable named &>/dev/null
    verificar_setup
}

listar_dominios() {
    echo ""
    echo "=== Dominios configurados ==="
    local zonas
    zonas=$(ls "$ZONES_DIR"/*.zone 2>/dev/null)
    if [[ -n "$zonas" ]]; then
        for f in $zonas; do
            echo "  - $(basename "$f" .zone)"
        done
    else
        echo "No se encontraron dominios configurados."
    fi
    read -p "Presione Enter..."
}

agregar_dominio() {
    echo ""
    echo "=== Agregar nuevo dominio ==="
    if ! paquete_instalado "bind"; then
        echo "[Error] Instale el servicio primero."
        read -p "Presione Enter..."; return
    fi

    read -p "Nombre del dominio (ej: empresa.local): " dominio
    while [[ -z "$dominio" ]]; do
        echo "[Error] El dominio no puede estar vacio."
        read -p "Nombre del dominio: " dominio
    done

    read -p "IP para el dominio [Enter = IP de enp0s8]: " ip_dominio
    if [[ -z "$ip_dominio" ]]; then
        ip_dominio=$(ip -br addr show enp0s8 | awk '{print $3}' | cut -d'/' -f1)
        echo "Usando IP: $ip_dominio"
    else
        validar_ip "$ip_dominio" || { echo "[Error] IP no valida."; sleep 2; return; }
    fi

    local zone_file="$ZONES_DIR/$dominio.zone"

    cat > "$zone_file" <<EOF
\$TTL 604800
@ IN SOA ns.$dominio. root.$dominio. (
    2
    604800
    86400
    2419200
    604800 )
@ IN NS ns.$dominio.
ns IN A $ip_dominio
@ IN A $ip_dominio
www IN CNAME $dominio.
EOF

    # CAMBIO: permisos correctos para que SELinux no bloquee el archivo de zona
    chown root:named "$zone_file"
    restorecon -Rv "$zone_file" &>/dev/null
    # FIN CAMBIO

    if grep -q "zone \"$dominio\"" "$ZONES_CONF" 2>/dev/null; then
        echo "[Aviso] El dominio '$dominio' ya existe."
    else
        cat >> "$ZONES_CONF" <<EOF

zone "$dominio" IN {
    type master;
    file "$zone_file";
    allow-update { none; };
};
EOF
    fi

    # CAMBIO: verificar sintaxis antes de reiniciar para no romper el servicio
    if named-checkconf "$NAMED_CONF"; then
        systemctl restart named
        echo -e "\n\e[32m[OK] Dominio '$dominio' agregado y apuntando a '$ip_dominio'.\e[0m"
    else
        echo -e "\n\e[31m[ERROR] Problema al configurar la zona. BIND no se reinicio.\e[0m"
    fi
    # FIN CAMBIO
    read -p "Presione Enter..."
}

eliminar_dominio() {
    echo ""
    echo "=== Eliminar dominio ==="
    if ! paquete_instalado "bind"; then
        echo "[Error] Instale el servicio primero."
        read -p "Presione Enter..."; return
    fi

    local zonas
    zonas=$(ls "$ZONES_DIR"/*.zone 2>/dev/null)
    if [[ -z "$zonas" ]]; then
        echo "No hay dominios para eliminar."
        read -p "Presione Enter..."; return
    fi

    echo "Dominios configurados:"
    for f in $zonas; do
        echo "  - $(basename "$f" .zone)"
    done

    read -p "Ingresa el nombre del dominio a eliminar: " dominio
    local zone_file="$ZONES_DIR/$dominio.zone"

    if [[ ! -f "$zone_file" ]]; then
        echo "[Error] El dominio '$dominio' no existe."
        read -p "Presione Enter..."; return
    fi

    read -p "¿Confirmar eliminacion de '$dominio'? (s/N): " conf
    if [[ "$conf" != "s" && "$conf" != "S" ]]; then
        echo "Cancelado."
        read -p "Presione Enter..."; return
    fi

    rm -f "$zone_file"

    # Backup y limpiar named.rfc1912.zones
    cp "$ZONES_CONF" "${ZONES_CONF}.bak"
    sed -i "/zone \"$dominio\" IN {/,/};/d" "$ZONES_CONF"

    systemctl restart named &>/dev/null
    echo -e "\e[32m[OK] Dominio '$dominio' eliminado.\e[0m"
    read -p "Presione Enter..."
}

# MENU MAIN

verificar_root

while true; do
    clear
    echo "========= MENÚ DNS ========="
    echo "1) Verificar instalacion"
    echo "2) Instalar dependencias"
    echo "3) Listar Dominios configurados"
    echo "4) Agregar nuevo dominio"
    echo "5) Eliminar un dominio"
    echo "6) Salir"
    echo "============================="
    echo ""
    read -p "Selecciona una opcion (1-6): " opcion

    case $opcion in
        "1") verificar_dns    ;;
        "2") instalar_dns     ;;
        "3") listar_dominios  ;;
        "4") agregar_dominio  ;;
        "5") eliminar_dominio ;;
        "6") exit 0           ;;
        *) echo "Opcion no valida."; sleep 1 ;;
    esac
done
