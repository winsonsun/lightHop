#!/bin/bash

# Target Configuration
REMOTE_HOST="root@192.168.20.23"
REMOTE_DIR="/etc/ss-tproxy"
DNSCRYPT_CONF_DIR="/etc/dnscrypt-proxy" # Adjust if your dnscrypt config is elsewhere

echo "=== Attempting Option 1: Remote Update via Domestic Mirrors ==="
ssh "$REMOTE_HOST" "
    set -e # Exit immediately if any command fails
    
    echo '[1/3] Downloading ss-tproxy lists using ghproxy.net...'
    curl -sL --fail --connect-timeout 10 https://ghproxy.net/https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf -o /etc/ss-tproxy/china-list.conf
    curl -sL --fail --connect-timeout 10 https://anti-ad.net/anti-ad-for-dnsmasq.conf -o /etc/ss-tproxy/anti-ad.conf
    curl -sL --fail --connect-timeout 10 http://ftp.apnic.net/apnic/stats/apnic/delegated-apnic-latest -o /etc/ss-tproxy/delegated-apnic-latest
    
    echo '[2/3] Downloading dnscrypt-proxy registries using ghproxy.net...'
    curl -sL --fail --connect-timeout 10 https://ghproxy.net/https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v2/public-resolvers.md -o /etc/dnscrypt-proxy/public-resolvers.md
    curl -sL --fail --connect-timeout 10 https://ghproxy.net/https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/odoh-servers.md -o /etc/dnscrypt-proxy/odoh-servers.md
    curl -sL --fail --connect-timeout 10 https://ghproxy.net/https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/odoh-relays.md -o /etc/dnscrypt-proxy/odoh-relays.md
    curl -sL --fail --connect-timeout 10 https://ghproxy.net/https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v2/relays.md -o /etc/dnscrypt-proxy/relays.md

    echo '[3/3] Processing IP lists and Restarting Proxy Stack...'
    cat /etc/ss-tproxy/delegated-apnic-latest | grep CN | grep ipv4 | awk -F'|' '{printf(\"add chnroute %s/%d\n\", \$4, 32-log(\$5)/log(2))}' > /etc/ss-tproxy/chnroute.set
    cat /etc/ss-tproxy/delegated-apnic-latest | grep CN | grep ipv6 | awk -F'|' '{printf(\"add chnroute6 %s/%d\n\", \$4, \$5)}' > /etc/ss-tproxy/chnroute6.set

    systemctl restart dnscrypt-proxy 2>/dev/null || echo 'dnscrypt-proxy not managed by systemd'
    /usr/local/bin/ss-tproxy restart
"

if [ $? -eq 0 ]; then
    echo "=== Provisioning Complete! (via Remote Mirrors) ==="
    exit 0
fi

echo ""
echo "=== Remote mirrors failed. Falling back to Option 3: Local Sync ==="
TMP_DIR=$(mktemp -d)

# 1. Download ss-tproxy related lists locally
echo "[1/3] Downloading DNS routing and ad-block lists locally..."
curl -sL --fail https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf -o "$TMP_DIR/china-list.conf"
curl -sL --fail https://anti-ad.net/anti-ad-for-dnsmasq.conf -o "$TMP_DIR/anti-ad.conf"
curl -sL --fail http://ftp.apnic.net/apnic/stats/apnic/delegated-apnic-latest -o "$TMP_DIR/delegated-apnic-latest"

# 2. Download dnscrypt-proxy registry lists locally
echo "[2/3] Downloading dnscrypt-proxy registries locally..."
curl -sL --fail https://download.dnscrypt.info/resolvers-list/v2/public-resolvers.md -o "$TMP_DIR/public-resolvers.md"
curl -sL --fail https://download.dnscrypt.info/resolvers-list/v3/odoh-servers.md -o "$TMP_DIR/odoh-servers.md"
curl -sL --fail https://download.dnscrypt.info/resolvers-list/v3/odoh-relays.md -o "$TMP_DIR/odoh-relays.md"
curl -sL --fail https://download.dnscrypt.info/resolvers-list/v2/relays.md -o "$TMP_DIR/relays.md"

# 3. Securely Sync to Remote Node
echo "[3/3] Pushing files to node $REMOTE_HOST..."
scp -q "$TMP_DIR"/*.conf "$TMP_DIR"/delegated-apnic-latest "$REMOTE_HOST:$REMOTE_DIR/"
scp -q "$TMP_DIR"/*.md "$REMOTE_HOST:$DNSCRYPT_CONF_DIR/"

# 4. Process and Restart Services on Node
echo "=== Applying Configurations on Node ==="
ssh "$REMOTE_HOST" "
    echo 'Processing APNIC routing list...'
    cat /etc/ss-tproxy/delegated-apnic-latest | grep CN | grep ipv4 | awk -F'|' '{printf(\"add chnroute %s/%d\n\", \$4, 32-log(\$5)/log(2))}' > /etc/ss-tproxy/chnroute.set
    cat /etc/ss-tproxy/delegated-apnic-latest | grep CN | grep ipv6 | awk -F'|' '{printf(\"add chnroute6 %s/%d\n\", \$4, \$5)}' > /etc/ss-tproxy/chnroute6.set

    echo 'Restarting Proxy Stack...'
    systemctl restart dnscrypt-proxy 2>/dev/null || echo 'dnscrypt-proxy not managed by systemd'
    /usr/local/bin/ss-tproxy restart
"

# Cleanup
rm -rf "$TMP_DIR"
echo "=== Provisioning Complete! (via Local Sync) ==="
