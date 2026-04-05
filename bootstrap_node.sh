#!/bin/bash
# Usage: ./bootstrap_node.sh ecosystem|cf-standalone

TYPE=$1
if [[ -z "$TYPE" ]]; then
    echo "Usage: $0 {ecosystem|cf-standalone}"
    exit 1
fi

if [ ! -f "bootstrap.conf" ]; then
    echo "[ERROR] bootstrap.conf not found!"
    exit 1
fi
source bootstrap.conf

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
    ssh "$REMOTE_HOST" "systemctl daemon-reload && systemctl enable sslocal-dns.service 2>/dev/null || true"

    # 4. Execute remote deployment logic
    echo "[4/4] Running remote deployment script..."
    ssh "$REMOTE_HOST" 'bash -s' < remote_deployment.sh

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
