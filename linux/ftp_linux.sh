#!/bin/bash

# Servidor FTP - Fedora

VERDE='\033[0;32m'
ROJO='\033[0;31m'
NORMAL='\033[0m'

ARCHIVO_LOG='/var/log/gestion_ftp.log'

# Rutas Base
RAIZ_FTP=
RAIZ_USUARIOS=
RAIZ_GRUPOS=
CARPETA_GENERAL=
CONF_VSFTPD=
LISTA_USUARIOS=

# ============== FUNCIONES ==============
