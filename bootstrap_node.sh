#!/bin/bash
# Usage: ./bootstrap_node.sh ecosystem|cf-standalone

TYPE=$1
if [[ -z "$TYPE" ]]; then
    echo "Usage: $0 {ecosystem|cf-standalone}"
    exit 1
fi

if [ ! -f "@config/bootstrap.conf" ]; then
    echo "[ERROR] @config/bootstrap.conf not found!"
    exit 1
fi
source @config/bootstrap.conf

# First, run preflight
./preflight-check.sh "$TYPE" || exit 1

if [ "$TYPE" == "ecosystem" ]; then
    echo "=== Deploying Integrated ss-tproxy Ecosystem ==="
    
    # 1. Push core binary
    echo "[1/4] Pushing ss-tproxy binary..."
    scp bin/ss-tproxy "$REMOTE_HOST:/usr/local/bin/ss-tproxy"
    ssh "$REMOTE_HOST" "chmod +x /usr/local/bin/ss-tproxy"
    
    # 2. Sync configurations from local backup
    echo "[2/4] Syncing local configuration backups to node..."
    rsync -avz --chown=root:root etc/ "$REMOTE_HOST:/etc/"
    
    # 3. Apply System Infrastructure Settings (Networking / OS)
    echo "[3/4] Applying OS & Networking Configurations..."
    ssh "$REMOTE_HOST" "sysctl -w net.ipv4.ip_forward=1 && echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-tproxy.conf"
    
    # Telemetry: Install Prometheus Node Exporter
    echo " -> Installing Prometheus Node Exporter for telemetry..."
    ssh "$REMOTE_HOST" "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq prometheus-node-exporter"
    ssh "$REMOTE_HOST" "systemctl enable prometheus-node-exporter && systemctl start prometheus-node-exporter"

    ssh "$REMOTE_HOST" "systemctl daemon-reload && systemctl enable sslocal-dns.service 2>/dev/null || true"

    # 4. Execute remote deployment logic
    echo "[4/4] Running remote deployment script..."
    
    export_vars=$(cat <<VARS
ENABLE_LAN_CONFIG='$ENABLE_LAN_CONFIG'
LAN_IFACES='${LAN_IFACES[*]}'
LAN_IFACE_START='$LAN_IFACE_START'
LAN_BASE_SUBNET='$LAN_BASE_SUBNET'
LAN_START_OCTET='$LAN_START_OCTET'
LAN_DHCP_START='$LAN_DHCP_START'
LAN_DHCP_END='$LAN_DHCP_END'
LAN_DHCP_LEASE='$LAN_DHCP_LEASE'
ENG_IP='$ENG_IP'
VARS
)
    ssh "$REMOTE_HOST" "bash -s" <<REMOTE
$export_vars
$(cat remote_deployment.sh)
REMOTE

    # Final verification
    echo "Verifying ecosystem status..."
    ssh "$REMOTE_HOST" "ss-tproxy status"

elif [ "$TYPE" == "cf-standalone" ]; then
    echo "=== Deploying Standalone CF Instance ==="
    
    # 1. Sync CF configurations from local backup
    echo "[1/2] Syncing CF configuration..."
    rsync -avz --chown=root:root etc/ "$REMOTE_HOST:/etc/"

    # 2. Enable and Start
    echo "[2/2] Starting standalone service..."
    ssh "$REMOTE_HOST" "systemctl daemon-reload && systemctl enable --now sslocal-cf 2>/dev/null || true"
    ssh "$REMOTE_HOST" "systemctl status sslocal-cf --no-pager"
fi

echo ""
echo "=== Bootstrap for $TYPE completed successfully! ==="
