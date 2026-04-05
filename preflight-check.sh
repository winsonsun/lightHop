#!/bin/bash
# Usage: ./preflight-check.sh ecosystem|cf-standalone

MODE=$1
if [[ -z "$MODE" ]]; then
    echo "Usage: $0 {ecosystem|cf-standalone}"
    exit 1
fi

if [ ! -f "bootstrap.conf" ]; then
    echo "[ERROR] bootstrap.conf not found!"
    exit 1
fi
source bootstrap.conf

check_port() {
    local port=$1
    if ssh "$REMOTE_HOST" "netstat -lnpt | grep -q ':$port '"; then
        echo "[!!] Port $port is already in use on $REMOTE_HOST!"
        return 1
    fi
    return 0
}

echo "=== Running Preflight Checks for $MODE ==="

# 0. Local Backup Validation
echo -n "[*] Checking Local Configurations... "
if [ "$MODE" == "ecosystem" ]; then
    if [ ! -d "etc/ss-tproxy" ] || [ ! -d "etc/systemd/system" ]; then
        echo "[FAIL] Missing 'etc/ss-tproxy' or 'etc/systemd/system'. Did you run backup_node_configs.sh?"
        exit 1
    fi
elif [ "$MODE" == "cf-standalone" ]; then
    if [ ! -d "etc/effective-tunnel/conf" ]; then
        echo "[FAIL] Missing 'etc/effective-tunnel/conf'. Did you run backup_node_configs.sh?"
        exit 1
    fi
fi
echo "[OK]"

# 1. SSH Connectivity
echo -n "[*] Checking SSH Connectivity... "
ssh -q -o ConnectTimeout=5 "$REMOTE_HOST" exit || { echo "[FAIL] Cannot connect to $REMOTE_HOST"; exit 1; }
echo "[OK]"

# 2. OS Compatibility
echo -n "[*] Checking OS Compatibility... "
OS=$(ssh "$REMOTE_HOST" "grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '\"'")
if [[ "$OS" =~ (debian|ubuntu) ]]; then
    echo "[OK] OS: $OS"
else
    echo "[WARN] OS is $OS. Script is optimized for Debian/Ubuntu."
fi

# 3. Port Checks
echo "[*] Checking Port Availability..."
FAILED_PORTS=0
if [ "$MODE" == "ecosystem" ]; then
    # We check if these are in use. If we are RE-bootstrapping, 
    # we expect them to be in use by our own services, which is fine.
    # This check is mostly to prevent clashing with UNKNOWN services.
    check_port 53 || ((FAILED_PORTS++))
    check_port 5310 || ((FAILED_PORTS++))
    check_port "$LOCAL_REDIR_PORT" || ((FAILED_PORTS++))
    check_port "$LOCAL_DNS_SOCKS_PORT" || ((FAILED_PORTS++))
else
    check_port "$LOCAL_CF_PORT" || ((FAILED_PORTS++))
fi

if [ $FAILED_PORTS -gt 0 ]; then
    echo "[INFO] Preflight detected $FAILED_PORTS active port(s). Ensure you are re-deploying or ports are freed."
fi
echo "[OK] All checks completed."

echo "=== Preflight finished! ==="
