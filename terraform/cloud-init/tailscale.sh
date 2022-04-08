#!/bin/bash

set -eo pipefail

tailscale up -authkey ${tailscale_auth_key} --advertise-routes=${tailscale_routes},168.63.129.16/32 --accept-dns=false
echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.conf
sysctl -p /etc/sysctl.conf
