#!/bin/bash
echo "--- ESTADO DE SISTEMA ---"
echo "Equipo: $(hostname)"
echo "IPs: $(hostname -I)"
df -h / | awk 'NR==2 {print "Disco: Usado " $3 " de " $2}'
