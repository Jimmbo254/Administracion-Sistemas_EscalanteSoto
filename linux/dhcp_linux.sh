#!/bin/bash
# dhcp_linux.sh — Servicio DHCP

. "./funciones_linux.sh"

# ============================================================
# FUNCIONES DHCP
# ============================================================

instalar_dhcp() {
    echo ""
    echo "==== Instalando DHCP ===="
    instalar_paquete "dhcp-server"
    read -p "Presione Enter..."
}

configurar_dhcp() {
    if ! paquete_instalado "dhcp-server"; then
        echo -e "\e[31mError: Instale el rol primero.\e[0m"
        read -p "Presione Enter..."
        return
    fi

    read -p "Nombre del nuevo Ambito: " nombreAmbito
    read -p "IP Inicial: " ipInicio
    validar_ip "$ipInicio" || { echo "IP no valida"; sleep 2; return; }

    read -p "IP Final: " ipFinal
    validar_ip "$ipFinal" || { echo "IP no valida"; sleep 2; return; }

    local inicio_int final_int
    inicio_int=$(ip_a_numero "$ipInicio")
    final_int=$(ip_a_numero "$ipFinal")

    if [ "$inicio_int" -ge "$final_int" ]; then
        echo -e "\e[31mError: La IP final debe ser mayor a la inicial.\e[0m"
        read -p "Presione Enter..."
        return
    fi

    read -p "Mascara de red: " mascara

    local ltime
    while true; do
        read -p "Lease Time en segundos: " ltime
        [[ -z "$ltime" ]] && ltime="3600" && break
        if [[ "$ltime" =~ ^[0-9]+$ ]] && [ "$ltime" -gt 0 ]; then
            break
        else
            echo -e "\e[31mError: Ingrese un numero entero mayor a 0.\e[0m"
        fi
    done

    read -p "Gateway: " gw
    read -p "DNS: " dns
    [[ -z "$gw"  ]] && gw="$ipInicio"
    [[ -z "$dns" ]] && dns="8.8.8.8"

    local prefix net_id
    prefix=$(ipcalc -p "$ipInicio" "$mascara" | cut -d= -f2)
    net_id=$(ipcalc -n  "$ipInicio" "$mascara" | cut -d= -f2)

    echo -e "\e[33mReconfigurando interfaz enp0s8 para cualquier clase...\e[0m"

    nmcli connection delete enp0s8 &>/dev/null
    nmcli connection add type ethernet ifname enp0s8 con-name enp0s8 \
        ipv4.method manual \
        ipv4.addresses "$ipInicio/$prefix" \
        ipv4.gateway "$gw" \
        ipv4.dns "$dns"
    ip addr flush dev enp0s8
    nmcli connection up enp0s8 &>/dev/null
    sleep 2

    bash -c "cat > /etc/dhcp/dhcpd.conf <<EOF
authoritative;
ddns-update-style none;

subnet $net_id netmask $mascara {
    range $ipInicio $ipFinal;
    option routers $gw;
    option domain-name-servers $dns;
    default-lease-time $ltime;
    max-lease-time $((ltime * 2));
}
EOF"

    mkdir -p /etc/systemd/system/dhcpd.service.d
    bash -c "cat > /etc/systemd/system/dhcpd.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/dhcpd -f -cf /etc/dhcp/dhcpd.conf -user dhcpd -group dhcpd --no-pid enp0s8
EOF"

    systemctl daemon-reload
    systemctl stop dhcpd &>/dev/null
    sh -c "> /var/lib/dhcpd/dhcpd.leases"

    if systemctl start dhcpd; then
        echo -e "\e[32m¡Servidor DHCP Activo en enp0s8!\e[0m"
        echo -e "\e[32mConfiguracion aplicada: $ipInicio con mascara $mascara\e[0m"
        ip addr show enp0s8 | grep "inet "
    else
        echo -e "\e[31mError al iniciar. Revisa journalctl -u dhcpd\e[0m"
    fi
    read -p "Presione Enter..."
}

monitoreo_dhcp() {
    echo "=== Monitorear ==="
    echo -e "\e[33m\nLeases activos:\e[0m"
    [ -f /var/lib/dhcpd/dhcpd.leases ] \
        && grep -E "lease|hostname|ends" /var/lib/dhcpd/dhcpd.leases \
        || echo "Sin leases."
    read -p "Presione Enter..."
}

eliminar_leases() {
    echo "=== Eliminar Leases ==="
    systemctl stop dhcpd
    sh -c "> /var/lib/dhcpd/dhcpd.leases"
    systemctl start dhcpd
    echo -e "\e[32mLeases limpiados.\e[0m"
    read -p "Presione Enter..."
}

desinstalar_dhcp() {
    echo "=== Desinstalar Servicio ==="
    desinstalar_paquete "dhcp-server"
    read -p "Presione Enter..."
}

# ============================================================
# MAIN
# ============================================================

verificar_root

while true; do
    clear
    echo "=== MENÚ DHCP FEDORA ==="
    echo ""
    echo "Opciones:"
    echo "1) Instalar DHCP Server"
    echo "2) Configurar red"
    echo "3) Monitoreo y estado"
    echo "4) Eliminar Leases"
    echo "5) Desinstalar"
    echo "6) Salir"
    echo ""
    read -p "Selecciona una opcion (1-6): " opcion

    case $opcion in
        "1") instalar_dhcp    ;;
        "2") configurar_dhcp  ;;
        "3") monitoreo_dhcp   ;;
        "4") eliminar_leases  ;;
        "5") desinstalar_dhcp ;;
        "6") exit 0           ;;
        *) echo "Opcion no valida."; sleep 1 ;;
    esac
done
