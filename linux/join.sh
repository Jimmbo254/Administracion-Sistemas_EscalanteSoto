#!/bin/bash

sudo apt update
sudo apt install -y realmd sssd sssd-tools adcli samba-common-bin oddjob oddjob-mkhomedir

sudo realm join empresa.local -U Administrator

sudo bash -c 'cat >> /etc/sssd/sssd.conf <<EOF
fallback_homedir = /home/%u@%d
EOF'

sudo chmod 600 /etc/sssd/sssd.conf
sudo systemctl restart sssd

echo "%domain admins@empresa.local ALL=(ALL) ALL" | sudo tee /etc/sudoers.d/ad-admins
