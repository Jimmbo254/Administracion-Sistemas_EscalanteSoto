#!/bin/bash
# dns_linux.sh — Servicio DNS linux

. "./funciones_linux.sh"

ZONES_DIR="/var/named"
NAMED_CONF="/etc/named.conf"
ZONES_CONF="/etc/named.rfc1912.zones"

# FUNCIONES DNS

verificar_setup() {
    echo "Verificando configuracion del servidor DNS..."
    # ------------
}

verificar_dns() {
    echo ""
    echo "=== Verificar instalacion DNS ==="
    if paquete_instalado "bind"; then
        echo "[OK] DNS service esta instalado"
    else
        echo "[Error] DNS service NO esta instalado"
    fi
    read -p "Presione Enter..."
}

instalar_dns() {
    echo ""
    echo "==== Instalando dependencias DNS ===="
    # --------------
    read -p "Presione Enter..."
}

listar_dominios() {
    echo ""
    echo "=== Dominios configurados ==="
    # ---------------
    read -p "Presione Enter..."
}

agregar_dominio() {
    echo ""
    echo "=== Agregar nuevo dominio ==="
    # ------------------
    read -p "Presione Enter..."
}

eliminar_dominio() {
    echo ""
    echo "=== Eliminar dominio ==="
    # --------------------
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
