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
