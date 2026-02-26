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

instalar_ssh() {
    echo ""
    echo "==== Instalando dependencias SSH ===="
    instalar_paquete "openssh-server" || { read -p "Presione Enter..."; return 1; }
    systemctl enable sshd
    systemctl start sshd
    firewall-cmd --permanent --add-service=ssh &>/dev/null
    firewall-cmd --reload &>/dev/null

    if systemctl is-active --quiet sshd; then
        echo -e "\e[32m[OK] SSH configurado correctamente.\e[0m"
    else
        echo -e "\e[31m[ERROR] SSH no pudo iniciarse.\e[0m"
    fi
    read -p "Presione Enter..."
}

desinstalar_ssh() {
    echo ""
    echo "=== Desinstalar SSH ==="
    echo -e "\e[33mATENCION: Desinstalar SSH cortara el acceso remoto.\e[0m"
    read -p "Escribe 'confirmar' para continuar: " conf
    if [[ "$conf" != "confirmar" ]]; then
        echo "Cancelado."
        read -p "Presione Enter..."; return
    fi
    systemctl stop sshd &>/dev/null
    systemctl disable sshd &>/dev/null
    firewall-cmd --permanent --remove-service=ssh &>/dev/null
    firewall-cmd --reload &>/dev/null
    desinstalar_paquete "openssh-server"
    read -p "Presione Enter..."
}

verificar_root

# ===== menu main =====

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
	"2") instalar_ssh ;;
	"3") desinstalar_ssh ;;
	"4") exit 0 ;;
	*) echo "Opcion no valida"; sleep 1 ;;
	esac
done
