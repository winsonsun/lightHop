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
    
    # 2. Setup SSLOCAL-DNS Systemd Service
    echo "[2/4] Configuring sslocal-dns backbone..."
    ssh "$REMOTE_HOST" "cat <<EOF > /etc/systemd/system/sslocal-dns.service
[Unit]
Description=Shadowsocks DNS Backbone (Port $LOCAL_DNS_SOCKS_PORT)
After=network.target

[Service]
Type=simple
User=root
LimitNPROC=5000000
LimitNOFILE=1000000
ExecStart=/usr/local/bin/ss-local -c /etc/effective-tunnel/conf/server-conf-aws.json -6
Restart=always

[Install]
WantedBy=multi-user.target
EOF"

    # 3. Execute remote deployment logic
    # Note: remote_deployment.sh handles config generation, logrotate, and hooks
    echo "[3/4] Running remote deployment script..."
    ssh "$REMOTE_HOST" 'bash -s' < remote_deployment.sh

    # 4. Final verification
    echo "[4/4] Verifying ecosystem status..."
    ssh "$REMOTE_HOST" "ss-tproxy status"

elif [ "$TYPE" == "cf-standalone" ]; then
    echo "=== Deploying Standalone CF Instance ==="
    
    # 1. Generate and push JSON
    echo "[1/3] Pushing CF configuration..."
    ssh "$REMOTE_HOST" "mkdir -p /etc/effective-tunnel/conf"
    ssh "$REMOTE_HOST" "cat <<EOF > /etc/effective-tunnel/conf/server-conf-cf.json
{
    \"server\": \"$SS_SERVER_CF\",
    \"server_port\": $SS_PORT_CF,
    \"local_address\": \"0.0.0.0\",
    \"local_port\": $LOCAL_CF_PORT,
    \"password\": \"$SS_PASS_CF\",
    \"timeout\": 600,
    \"method\": \"$SS_METHOD_CF\"
}
EOF"

    # 2. Create Systemd Service
    echo "[2/3] Configuring sslocal-cf service..."
    ssh "$REMOTE_HOST" "cat <<EOF > /etc/systemd/system/sslocal-cf.service
[Unit]
Description=Shadowsocks CF Standalone (Port $LOCAL_CF_PORT)
After=network.target

[Service]
Type=simple
User=root
LimitNPROC=5000000
LimitNOFILE=1000000
ExecStart=/usr/local/bin/ss-local -c /etc/effective-tunnel/conf/server-conf-cf.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF"
    
    # 3. Enable and Start
    echo "[3/3] Starting standalone service..."
    ssh "$REMOTE_HOST" "systemctl daemon-reload && systemctl enable --now sslocal-cf"
    ssh "$REMOTE_HOST" "systemctl status sslocal-cf --no-pager"
fi

echo ""
echo "=== Bootstrap for $TYPE completed successfully! ==="
