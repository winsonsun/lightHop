#!/bin/bash
set -e

# 1. Load Configuration
if [ ! -f "bootstrap.conf" ]; then
    echo "Error: bootstrap.conf not found in the current directory!"
    exit 1
fi
source bootstrap.conf

echo "=== Starting ss-tproxy Ecosystem Bootstrap ==="

# 2. System Dependencies
echo "[1/6] Installing system dependencies..."
apt-get update -y
apt-get install -y curl wget tar gzip ipset iptables iproute2 dnsmasq shadowsocks-libev jq

# 3. Download & Install dnscrypt-proxy (from GitHub Releases)
echo "[2/6] Installing dnscrypt-proxy..."
# Attempt to get the latest version tag (may require mirror if api.github.com is blocked)
DNSCRYPT_VER=$(curl -sL "https://api.github.com/repos/DNSCrypt/dnscrypt-proxy/releases/latest" | jq -r '.tag_name' || echo "2.1.5")
echo "Using dnscrypt-proxy version: $DNSCRYPT_VER"

wget -qO /tmp/dnscrypt.tar.gz "${GH_MIRROR}/DNSCrypt/dnscrypt-proxy/releases/download/${DNSCRYPT_VER}/dnscrypt-proxy-linux_x86_64-${DNSCRYPT_VER}.tar.gz"
tar -xzf /tmp/dnscrypt.tar.gz -C /tmp
mv /tmp/linux-x86_64/dnscrypt-proxy /usr/local/bin/
chmod +x /usr/local/bin/dnscrypt-proxy

mkdir -p /etc/dnscrypt-proxy
cp /tmp/linux-x86_64/example-dnscrypt-proxy.toml /etc/dnscrypt-proxy/dnscrypt-proxy.toml
sed -i "s/listen_addresses = .*/listen_addresses = ['${DNSCRYPT_LISTEN}']/" /etc/dnscrypt-proxy/dnscrypt-proxy.toml

cat > /etc/systemd/system/dnscrypt-proxy.service <<EOF
[Unit]
Description=DNSCrypt-proxy client
After=network.target

[Service]
ExecStart=/usr/local/bin/dnscrypt-proxy -config /etc/dnscrypt-proxy/dnscrypt-proxy.toml
Restart=on-abnormal

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now dnscrypt-proxy

# 4. Install ss-tproxy
echo "[3/6] Installing ss-tproxy core script..."
curl -sL "${RAW_MIRROR}/zfl9/ss-tproxy/master/ss-tproxy" -o /usr/local/bin/ss-tproxy
chmod +x /usr/local/bin/ss-tproxy
mkdir -p /etc/ss-tproxy

# 5. Configure Shadowsocks (ss-redir)
echo "[4/6] Configuring shadowsocks-libev..."
cat > /etc/shadowsocks-libev/config.json <<EOF
{
    "server": "${SS_SERVER}",
    "server_port": ${SS_PORT},
    "local_address": "0.0.0.0",
    "local_port": ${LOCAL_PROXY_PORT},
    "password": "${SS_PASSWORD}",
    "timeout": 300,
    "method": "${SS_METHOD}",
    "mode": "tcp_and_udp"
}
EOF

# Create the specific group for GID bypass
groupadd -g 23333 tproxyadmin 2>/dev/null || true

# Patch the systemd service to run ss-redir under the new group
mkdir -p /etc/systemd/system/shadowsocks-libev-ss-redir@.service.d
cat > /etc/systemd/system/shadowsocks-libev-ss-redir@.service.d/override.conf <<EOF
[Service]
Group=tproxyadmin
EOF
systemctl daemon-reload
systemctl enable --now shadowsocks-libev-ss-redir@config

# 6. Configure ss-tproxy
echo "[5/6] Generating optimized ss-tproxy.conf..."
cat > /etc/ss-tproxy/ss-tproxy.conf <<EOF
mode='chnroute'
ipv4='true'
ipv6='true'
tproxy='false'
tcponly='false'
selfonly='false'

proxy_procgroup='23333'
proxy_tcpport='${LOCAL_PROXY_PORT}'
proxy_udpport='${LOCAL_PROXY_PORT}'
proxy_startcmd='systemctl start shadowsocks-libev-ss-redir@config'
proxy_stopcmd='systemctl stop shadowsocks-libev-ss-redir@config'

dns_direct='119.29.29.29'
dns_direct6='240C::6666'
dns_remote='${DNSCRYPT_LISTEN//:/#}'

dnsmasq_bind_port='53'
dnsmasq_cache_size='10000'
dnsmasq_query_maxcnt='1024'
dnsmasq_log_enable='false'
dnsmasq_log_file='/var/log/dnsmasq.log'

ipts_if_lo='lo'
ipts_rt_tab='233'
ipts_rt_mark='0x2333'
ipts_set_snat='true'
ipts_set_snat6='true'
ipts_reddns_onstop='true'
ipts_proxy_dst_port='1:57488,57501:65535'

file_gfwlist_txt='/etc/ss-tproxy/gfwlist.txt'
file_gfwlist_ext='/etc/ss-tproxy/gfwlist.ext'
file_ignlist_ext='/etc/ss-tproxy/ignlist.ext'
file_chnroute_set='/etc/ss-tproxy/chnroute.set'
file_chnroute6_set='/etc/ss-tproxy/chnroute6.set'
file_dnsserver_pid='/etc/ss-tproxy/.dnsserver.pid'

## custom hook
# Subnets that SHOULD be proxied
proxy_subnets=(
$(for sub in "${PROXY_SUBNETS[@]}"; do echo "    \"$sub\""; done)
)

post_start() {
    ipset create proxy_subnets hash:net 2>/dev/null || ipset flush proxy_subnets
    for subnet in "\${proxy_subnets[@]}"; do
        ipset add proxy_subnets "\$subnet"
    done
    # Gatekeeper: Bypass proxy for non-matching subnets
    iptables -t nat -I SSTP_PREROUTING 1 -m set ! --match-set proxy_subnets src -j RETURN
    iptables -t mangle -I SSTP_PREROUTING 1 -m set ! --match-set proxy_subnets src -j RETURN
}

post_stop() {
    ipset destroy proxy_subnets 2>/dev/null
}

## optimized dns override
start_dnsserver_chnroute() {
    local base_config=\$(echo "\$dnsmasq_common_config" | sed -E 's/^[[:space:]]*(cache-size|no-resolv|server)[[:space:]]*=.*\$//g')
    local dnsmasq_config_string="\$(cat <<EOT
\$base_config
server=\$dns_remote
cache-size=10000
no-resolv
conf-file=/etc/ss-tproxy/china-list.conf
conf-file=/etc/ss-tproxy/anti-ad.conf
EOT
)"
    status_dnsmasq_pid=\$(dnsmasq --keep-in-foreground --conf-file=- <<<"\$dnsmasq_config_string" & echo \$!)
    status_chinadns_pid=""
}
EOF

# 7. Initial List Download & Startup
echo "[6/6] Downloading initial routing/ad-blocking lists..."
curl -sL --connect-timeout 10 "${RAW_MIRROR}/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf" -o /etc/ss-tproxy/china-list.conf
curl -sL --connect-timeout 10 "https://anti-ad.net/anti-ad-for-dnsmasq.conf" -o /etc/ss-tproxy/anti-ad.conf
curl -sL --connect-timeout 10 "http://ftp.apnic.net/apnic/stats/apnic/delegated-apnic-latest" -o /etc/ss-tproxy/delegated-apnic-latest

# Process APNIC IPs
cat /etc/ss-tproxy/delegated-apnic-latest | grep CN | grep ipv4 | awk -F'|' '{printf("add chnroute %s/%d\n", $4, 32-log($5)/log(2))}' > /etc/ss-tproxy/chnroute.set
cat /etc/ss-tproxy/delegated-apnic-latest | grep CN | grep ipv6 | awk -F'|' '{printf("add chnroute6 %s/%d\n", $4, $5)}' > /etc/ss-tproxy/chnroute6.set

echo "Finalizing system configuration..."
systemctl disable systemd-resolved 2>/dev/null || true
systemctl stop systemd-resolved 2>/dev/null || true
/usr/local/bin/ss-tproxy start

echo "=== Bootstrap Complete! Node is fully operational. ==="
