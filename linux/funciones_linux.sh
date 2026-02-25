#!/bin/bash

#FUNCIONES BASICAS LINUX

verificar_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error: Ejecutar con sudo"
        exit 1
    fi
}

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

paquete_instalado() {
    rpm -q "$1" &>/dev/null
}

instalar_paquete() {
    local paquete=$1
    if paquete_instalado "$paquete"; then
        echo "$paquete ya esta instalado."
        return 0
    fi
    echo "Instalando $paquete..."
    if dnf install -y "$paquete"; then
        echo "Instalacion completada."
    else
        echo -e "\e[31mError: Fallo la instalacion de $paquete.\e[0m"
        return 1
    fi
}

desinstalar_paquete() {
    local paquete=$1
    if ! paquete_instalado "$paquete"; then
        echo -e "\e[31mError: $paquete no esta instalado.\e[0m"
        return 1
    fi
    dnf remove -y "$paquete" && echo "SERVICIO DESINSTALADO CORRECTAMENTE"
}
