#!/bin/bash
# Usage: ./backup_node_configs.sh

if [ ! -f "bootstrap.conf" ]; then
    echo "[ERROR] bootstrap.conf not found!"
    exit 1
fi
source bootstrap.conf

echo "=== Pulling configurations from $REMOTE_HOST ==="

mkdir -p etc/effective-tunnel/conf
mkdir -p etc/systemd/system
mkdir -p etc/ss-tproxy
mkdir -p etc/dnsmasq.d

echo "[1/3] Pulling Proxy Client Configurations..."
rsync -avz --ignore-missing-args "$REMOTE_HOST:/etc/effective-tunnel/conf/*.json" etc/effective-tunnel/conf/ 2>/dev/null || echo "No json configs found."
rsync -avz --ignore-missing-args "$REMOTE_HOST:/etc/systemd/system/sslocal-*.service" "$REMOTE_HOST:/etc/systemd/system/ssredir.service" etc/systemd/system/ 2>/dev/null || echo "No proxy services found."

echo "[2/3] Pulling DNS Resolver Configurations..."
rsync -avz --ignore-missing-args "$REMOTE_HOST:/etc/dnsmasq.conf" etc/ 2>/dev/null || echo "No dnsmasq.conf found."
rsync -avz --ignore-missing-args "$REMOTE_HOST:/etc/dnsmasq.d/*" etc/dnsmasq.d/ 2>/dev/null || echo "No dnsmasq.d configs found."
rsync -avz --ignore-missing-args "$REMOTE_HOST:/etc/logrotate.d/dnsmasq" etc/ 2>/dev/null || echo "No logrotate for dnsmasq found."

echo "[3/3] Pulling ss-tproxy Core Configurations..."
rsync -avz "$REMOTE_HOST:/etc/ss-tproxy/ss-tproxy.conf" etc/ss-tproxy/ 2>/dev/null || echo "ss-tproxy.conf not found."
rsync -avz --ignore-missing-args "$REMOTE_HOST:/etc/ss-tproxy/*.ext" etc/ss-tproxy/ 2>/dev/null || echo "No custom .ext rules found."

echo "=== Backup Complete! ==="
echo "You can now commit these files to your repository."
