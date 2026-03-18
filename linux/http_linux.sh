#!/bin/bash
# http_linux.sh — Servidor Web Fedora (Main)

. "./http_functions.sh"

if [ "$EUID" -ne 0 ]; then
    echo "[Error] Ejecuta el script como root: sudo bash http_linux.sh"
    exit 1
fi

while true; do
    clear
    echo "========= MENÚ HTTP ========="
    echo "1) Instalar Apache (httpd)"
    echo "2) Instalar Nginx"
    echo "3) Instalar Tomcat"
    echo "4) Verificar servicio"
    echo "5) Desinstalar servidor"
    echo "6) Cambiar version"
    echo "7) Limpiar entorno"
    echo "8) Levantar/Reiniciar servicio"
    echo "0) Salir"
    echo "============================="
    echo ""
    read -p "Selecciona una opcion: " opcion

    case "$opcion" in
        1) flujo_instalar "apache" "Apache (httpd)" ;;
        2) flujo_instalar "nginx"  "Nginx"          ;;
        3) flujo_instalar "tomcat" "Tomcat"         ;;
        4) flujo_verificar                          ;;
        5) quitar_servidor                          ;;
        6) actualizar_servidor                      ;;
        7)
            read -p "  ¿Confirmar limpieza total del entorno? (s/N): " conf
            [[ "$conf" =~ ^[sS]$ ]] && limpiar_entorno
            ;;
        8) reiniciar_servidor                       ;;
        0) echo "  Cerrando..."; exit 0             ;;
        *) echo "  [Error] Opcion no valida."; sleep 1 ;;
    esac
    echo ""; read -p "  Presiona Enter para continuar..."
done
