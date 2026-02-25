#!/bin/bash

# dns_linux.sh - Servicio DNS / BIND9

. "./funciones_linux.sh"

verificar_dns() {
	echo ""
	echo "=== Verificar instalacion DNS ==="
	if paquete_instalado "bind"; then
		echo -e "\e[32mBIND9 esta instalado.\e[0m"
		systemctl status named --no-pager
	else
		echo -e "\e[31mBIND9 NO esta instalado.\e[0m"
	fi
	read -p "Presione Enter..."
}

instalar_dns() {
    echo ""
    echo "==== Instalando BIND9 (DNS) ===="
    instalar_paquete "bind"
    instalar_paquete "bind-utils"
    read -p "Presione Enter..."
}

listar_dominios() {
    echo "=== Dominios configurados ==="
    local zonas=()
    while IFS= read -r -d '' f; do zonas+=("$f"); done \
        < <(find /var/named -maxdepth 1 -name "*.zone" -print0 2>/dev/null)

    if [[ ${#zonas[@]} -eq 0 ]]; then
        echo "No hay dominios configurados."
    else
        for f in "${zonas[@]}"; do
            echo ""
            echo "--- $(basename "$f" .zone) ---"
            cat "$f"
        done
    fi
    read -p "Presione Enter..."
}

agregar_dominio() {
    if ! paquete_instalado "bind"; then
        echo -e "\e[31mError: Instale el servicio primero.\e[0m"
        read -p "Presione Enter..."; return
    fi

    read -p "Nombre del dominio (ej: empresa.local): " dominio
    if [[ -z "$dominio" ]]; then
        echo -e "\e[31mError: El dominio no puede estar vacio.\e[0m"
        sleep 2; return
    fi

    while true; do
        read -p "IP del servidor DNS: " ip_servidor
        validar_ip "$ip_servidor" && break
        echo -e "\e[31mIP no valida.\e[0m"
    done

    read -p "Red base (ej: 192.168.1): " red_base
    read -p "Hostname del servidor (ej: ns1): " ns_host
    [[ -z "$ns_host" ]] && ns_host="ns1"

    IFS='.' read -r -a partes <<< "$red_base"
    local zona_inversa="${partes[2]}.${partes[1]}.${partes[0]}.in-addr.arpa"
    local ultimo_octeto
    ultimo_octeto=$(echo "$ip_servidor" | cut -d. -f4)
    local serial
    serial=$(date +%Y%m%d01)

    local archivo_zona="/var/named/$dominio.zone"
    local archivo_rev="/var/named/$dominio.rev"

    cat > "$archivo_zona" <<EOF
\$TTL 86400
@   IN  SOA ${ns_host}.${dominio}. admin.${dominio}. (
            $serial ; Serial
            3600    ; Refresh
            1800    ; Retry
            604800  ; Expire
            86400 ) ; Minimum TTL
@       IN  NS  ${ns_host}.${dominio}.
${ns_host}  IN  A   ${ip_servidor}
EOF

    cat > "$archivo_rev" <<EOF
\$TTL 86400
@   IN  SOA ${ns_host}.${dominio}. admin.${dominio}. (
            $serial ; Serial
            3600    ; Refresh
            1800    ; Retry
            604800  ; Expire
            86400 ) ; Minimum TTL
@                IN  NS  ${ns_host}.${dominio}.
${ultimo_octeto}  IN  PTR ${ns_host}.${dominio}.
EOF

    chown named:named "$archivo_zona" "$archivo_rev"
    chmod 640 "$archivo_zona" "$archivo_rev"

    if grep -q "zone \"$dominio\"" /etc/named.conf 2>/dev/null; then
        echo -e "\e[33mEl dominio '$dominio' ya existe en named.conf.\e[0m"
    else
        cat >> /etc/named.conf <<EOF

zone "$dominio" IN {
    type master;
    file "$archivo_zona";
    allow-update { none; };
};

zone "$zona_inversa" IN {
    type master;
    file "$archivo_rev";
    allow-update { none; };
};
EOF
    fi

    named-checkconf /etc/named.conf && named-checkzone "$dominio" "$archivo_zona" || {
        echo -e "\e[31mError de sintaxis. Revisa los archivos.\e[0m"
        read -p "Presione Enter..."; return
    }

    systemctl enable named &>/dev/null
    if systemctl restart named; then
        echo -e "\e[32mBIND9 activo con dominio '$dominio'.\e[0m"
    else
        echo -e "\e[31mError al iniciar named. Revisa journalctl -u named\e[0m"
    fi
    read -p "Presione Enter..."
}

eliminar_dominio() {
    if ! paquete_instalado "bind"; then
        echo -e "\e[31mError: Instale el servicio primero.\e[0m"
        read -p "Presione Enter..."; return
    fi

    local zonas=()
    while IFS= read -r -d '' f; do
        zonas+=("$(basename "$f" .zone)")
    done < <(find /var/named -maxdepth 1 -name "*.zone" -print0 2>/dev/null)

    if [[ ${#zonas[@]} -eq 0 ]]; then
        echo "No hay dominios configurados."
        read -p "Presione Enter..."; return
    fi

    echo "Dominios disponibles:"
    for i in "${!zonas[@]}"; do echo "  $((i+1))) ${zonas[$i]}"; done
    read -p "Selecciona dominio a eliminar (numero): " sel
    local dominio="${zonas[$((sel-1))]}"

    read -p "¿Confirmar eliminacion de '$dominio'? (s/N): " conf
    if [[ "$conf" != "s" && "$conf" != "S" ]]; then
        echo "Cancelado."
        read -p "Presione Enter..."; return
    fi

    rm -f "/var/named/$dominio.zone" "/var/named/$dominio.rev"

    python3 - /etc/named.conf "$dominio" <<'PYEOF'
import sys, re
conf, dom = sys.argv[1], sys.argv[2]
with open(conf) as f: content = f.read()
content = re.sub(r'\nzone "' + re.escape(dom) + r'[^"]*" IN \{[^}]+\};\n', '', content)
with open(conf, 'w') as f: f.write(content)
PYEOF

    systemctl reload named &>/dev/null
    echo -e "\e[32mDominio '$dominio' eliminado.\e[0m"
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
