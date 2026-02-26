#!/bin/bash

# ssh_linux.sh - Servicio SSH Fedora

. "./funciones_linux.sh"

# FUNCIONES SSH

revision_ssh() {
	echo ""
	echo "=== Verificar instalacion SSH ==="
	if paquete_instalado "openssh-server"; then
		echo "[OK] OpenSSH esta instalado"
	else
		echo "[Error] OpenSSH NO esta instalado"
	fi

	if systemctl is-active sshd &>/dev/null; then
		echo "[OK] Servicio ACTIVO"
	else
		echo "[Error] Servicio NO activo"
	fi

	if systemctl is-enabled sshd &>/dev/null; then
		echo "[OK] Servicio habilitado en boot"
	else
		echo "[Error] Servicio NO habilitado en boot"
	fi
	read -p "Presiona Enter..."
}

verificar_root

while true; do
	clear
	echo "======== MENU SSH ========="
	echo "1) Verificar instalacion"
	echo "2) Instalar dependencias"
	echo "3) Desinstalar"
	echo "4) Salir"
	echo "==========================="
	read -p "Selecciona una opcion (1-4): " opcion

	case $opcion in
	"1") revision_ssh ;;
	"2") ;;
	"3") ;;
	"4") exit 0 ;;
	*) echo "Opcion no valida"; sleep 1 ;;
	esac
done
