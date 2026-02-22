#!/bin/bash

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
