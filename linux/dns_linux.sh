#!/bin/bash

# dns_linux.sh - Servicio DNS / BIND9

. "./funciones_linux.sh"

ZONES_DIR="/etc/bind/zones"
NAMED_CONF="/etc/named.conf"

verificar_dns() {
    echo ""
    echo "=== Verificar instalacion DNS ==="
    if paquete_instalado "bind"; then
        echo "[OK] DNS service esta instalado"
    else
        echo "[Error] DNS service NO esta instalado"
        read -p "Presione Enter..."; return
    fi

    # Verificar named.conf
    if grep -q "allow-query { any; };" "$NAMED_CONF" &&
       grep -q "listen-on port 53 { any; };" "$NAMED_CONF"; then
        echo "[OK] named.conf configurado correctamente"
    else
        echo "[Error] named.conf no esta configurado"
    fi

    # Verificar interfaz
    local state_ip ip_value
    state_ip=$(ip -br addr show enp0s8 | awk '{print $2}')
    ip_value=$(ip -br addr show enp0s8 | awk '{print $3}')
    if [[ "$state_ip" == "UP" && -n "$ip_value" ]]; then
        echo "[OK] Interfaz enp0s8 activa con IP: $ip_value"
    else
        echo "[Error] Interfaz enp0s8 no activa o sin IP"
    fi

    # Verificar firewall
    if firewall-cmd --list-services | grep -qw dns; then
        echo "[OK] Puerto DNS abierto en firewall"
    else
        echo "[Error] Puerto DNS no abierto en firewall"
    fi

    systemctl status named --no-pager
    read -p "Presione Enter..."
}

instalar_dns() {
    echo ""
    echo "==== Instalando BIND9 (DNS) ===="
    instalar_paquete "bind"
    instalar_paquete "bind-utils"
    instalar_paquete "ipcalc"

    # Configurar named.conf para escuchar en cualquier IP
    if ! grep -q "allow-query { any; };" "$NAMED_CONF"; then
        sed -i '
/^[[:space:]]*options[[:space:]]*{/ {
    :a
    n
    /^[[:space:]]*};/ b
    /allow-query/d
    /listen-on port/d
    /listen-on-v6/d
    ba
}
' "$NAMED_CONF"

        sed -i '/^[[:space:]]*options[[:space:]]*{/a\
    allow-query { any; };\
    listen-on port 53 { any; };\
    listen-on-v6 port 53 { any; };' "$NAMED_CONF"

        echo "[OK] named.conf actualizado"
    else
        echo "[OK] named.conf ya estaba configurado"
    fi

    # Abrir puerto DNS en firewall
    if ! firewall-cmd --list-services | grep -qw dns; then
        firewall-cmd --add-service=dns --permanent
        firewall-cmd --reload
        echo "[OK] Puerto DNS abierto en firewall"
    fi

    # Crear directorio de zonas
    mkdir -p "$ZONES_DIR"

    systemctl enable named &>/dev/null
    systemctl restart named \
        && echo -e "[OK] Servicio named activo." \
        || echo "[Error] Fallo al iniciar named."
    read -p "Presione Enter..."
}

listar_dominios() {
    echo ""
    echo "=== Dominios configurados ==="
    if [[ -d "$ZONES_DIR" ]]; then
        local encontrados=0
        for f in "$ZONES_DIR"/*.zone; do
            [[ -f "$f" ]] && echo "  - $(basename "$f" .zone)" && encontrados=1
        done
        [[ $encontrados -eq 0 ]] && echo "No hay dominios configurados."
    else
        echo "No existe el directorio $ZONES_DIR."
    fi
    read -p "Presione Enter..."
}

agregar_dominio() {
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

    mkdir -p "$ZONES_DIR"

    cat > "$ZONES_DIR/$dominio.zone" <<EOF
\$TTL 604800
@ IN SOA ns.$dominio. root.$dominio. (
    2;
    604800;
    86400;
    2419200;
    604800)
;
@ IN NS $dominio.
@ IN A $ip_dominio
www IN CNAME $dominio.
EOF

    # Agregar zona a named.conf si no existe
    if grep -q "zone \"$dominio\"" "$NAMED_CONF" 2>/dev/null; then
        echo "[Aviso] El dominio '$dominio' ya existe en named.conf."
    else
        cat >> "$NAMED_CONF" <<EOF

zone "$dominio" IN {
    type master;
    file "$ZONES_DIR/$dominio.zone";
};
EOF
        echo "[OK] Dominio '$dominio' agregado a named.conf."
    fi

    named-checkconf "$NAMED_CONF" && systemctl restart named \
        && echo "[OK] Dominio '$dominio' activo." \
        || echo "[Error] Revisa journalctl -u named"
    read -p "Presione Enter..."
}

eliminar_dominio() {
    if ! paquete_instalado "bind"; then
        echo "[Error] Instale el servicio primero."
        read -p "Presione Enter..."; return
    fi

    if [[ ! -d "$ZONES_DIR" ]]; then
        echo "No existe el directorio $ZONES_DIR."
        read -p "Presione Enter..."; return
    fi

    echo "Dominios configurados:"
    local zonas=()
    for f in "$ZONES_DIR"/*.zone; do
        [[ -f "$f" ]] && zonas+=("$(basename "$f" .zone)")
    done

    if [[ ${#zonas[@]} -eq 0 ]]; then
        echo "No hay dominios para eliminar."
        read -p "Presione Enter..."; return
    fi

    for i in "${!zonas[@]}"; do echo "  $((i+1))) ${zonas[$i]}"; done
    read -p "Selecciona dominio a eliminar (numero): " sel
    local dominio="${zonas[$((sel-1))]}"

    read -p "¿Confirmar eliminacion de '$dominio'? (s/N): " conf
    if [[ "$conf" != "s" && "$conf" != "S" ]]; then
        echo "Cancelado."
        read -p "Presione Enter..."; return
    fi

    # Borrar archivo de zona
    rm -f "$ZONES_DIR/$dominio.zone"

    # Backup y limpiar named.conf
    cp "$NAMED_CONF" "${NAMED_CONF}.bak"
    sed -i "/zone \"$dominio\" IN {/,/};/d" "$NAMED_CONF"

    systemctl restart named &>/dev/null
    echo "[OK] Dominio '$dominio' eliminado."
    read -p "Presione Enter..."
}

# ============================================================
# MAIN
# ============================================================

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
