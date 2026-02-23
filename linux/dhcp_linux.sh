#!/bin/bash

validar_ip() {
    local ip=$1
    if [[ $ip == "0.0.0.0" || $ip == "255.255.255.255" || $ip == "127.0.0.1" ]]; then
        return 1
    fi
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octetos <<< "$ip"
        for octeto in "${octetos[@]}"; do
            if [[ $octeto -lt 0 || $octeto -gt 255 ]]; then return 1; fi
        done
        return 0
    fi
    return 1
}

ip_a_numero() {
    local a b c d
    IFS='.' read -r a b c d <<< "$1"
    echo "$(( (a << 24) + (b << 16) + (c << 8) + d ))"
}

# verificacion de privilegios
if [[ $EUID -ne 0 ]]; then
	echo "error: Ejecutar con sudo"
	exit 1
fi

# menu principal
while true; do
clear

	echo "=== MENÚ DHCP FEDORA ==="
	echo""
	echo "Opciones:"
	echo "1) Instalar DHCP Server"
	echo "2) Configurar red"
	echo "3) Monitoreo y estado"
	echo "4) Desinstalar"
	echo ""
	read -p "Selecciona una opción (1-4): " opcion

	case $opcion in
		1)
			echo ""
			echo "==== Instalando DHCP ===="

			if rpm -q dhcp-server >/dev/null 2>&1; then
				echo "dhcp-server YA INSTALADO"
			else
				echo "Instalando dhcp-server..."
				if dnf install -y dhcp-server; then
					echo "INSTALACION COMPLETADA"
				else
					echo "ERROR: Fallo instalacion"
					read -p "Presione enter..."
					continue
				fi
			fi
			read -p "Presione Enter..."
			;;
		2)
		3)
		4)
	esac
done
