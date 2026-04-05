#!/bin/bash
set -e

# 1. Update log_enable to false
sed -i "s/^dnsmasq_log_enable=.*/dnsmasq_log_enable='false'/" /etc/ss-tproxy/ss-tproxy.conf

# 2. Setup logrotate for dnsmasq
cat << 'LOGROTATE' > /etc/logrotate.d/dnsmasq
/var/log/dnsmasq.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        systemctl kill -s USR2 dnsmasq 2>/dev/null || true
    endscript
}
LOGROTATE

# 3. Create systemd service for sslocal-dns
cat << 'SSLOCAL' > /etc/systemd/system/sslocal-dns.service
[Unit]
Description=Shadowsocks-Libev Custom Local Client for DNS
Documentation=man:ss-local(1)
After=network.target

[Service]
Type=simple
User=root
LimitNPROC=5000000
LimitNOFILE=1000000
ExecStart=/usr/local/bin/ss-local -c /etc/effective-tunnel/conf/server-conf-aws.json -6

[Install]
WantedBy=multi-user.target
SSLOCAL

systemctl daemon-reload
systemctl enable sslocal-dns.service

# 4. Update proxy_startcmd and proxy_stopcmd in ss-tproxy.conf
sed -i "s|^proxy_startcmd=.*|proxy_startcmd='systemctl start ssredir \&\& systemctl start sslocal-dns'|" /etc/ss-tproxy/ss-tproxy.conf
sed -i "s|^proxy_stopcmd=.*|proxy_stopcmd='systemctl stop sslocal-dns ; systemctl stop ssredir'|" /etc/ss-tproxy/ss-tproxy.conf

# Kill existing ss-local on port 10298 to free the port before restart
kill $(netstat -lnpt | grep 10298 | awk '{print $7}' | cut -d'/' -f1) 2>/dev/null || true

# 5. Rebuild the custom hook in ss-tproxy.conf
sed -i '/## custom hook/,$d' /etc/ss-tproxy/ss-tproxy.conf

cat << 'HOOKS' >> /etc/ss-tproxy/ss-tproxy.conf
## custom hook
proxy_subnets=(
    "10.10.6.0/24"
)

proxy_subnets6=(
    # Add IPv6 subnets here if any, e.g., "fc00::/7"
)

post_start() {
    # IPv4 Subnet routing
    ipset create proxy_subnets hash:net family inet 2>/dev/null || ipset flush proxy_subnets
    for subnet in "${proxy_subnets[@]}"; do
        ipset add proxy_subnets "$subnet"
    done
    iptables -t nat -I SSTP_PREROUTING 1 -m set ! --match-set proxy_subnets src -j RETURN
    iptables -t mangle -I SSTP_PREROUTING 1 -m set ! --match-set proxy_subnets src -j RETURN

    # IPv6 Subnet routing (Leak correction)
    ipset create proxy_subnets6 hash:net family inet6 2>/dev/null || ipset flush proxy_subnets6
    for subnet in "${proxy_subnets6[@]}"; do
        ipset add proxy_subnets6 "$subnet"
    done
    ip6tables -t nat -I SSTP_PREROUTING 1 -m set ! --match-set proxy_subnets6 src -j RETURN
    ip6tables -t mangle -I SSTP_PREROUTING 1 -m set ! --match-set proxy_subnets6 src -j RETURN

    # TCP MSS Clamping to prevent MTU issues
    iptables -t mangle -I FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    ip6tables -t mangle -I FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
}

post_stop() {
    ipset destroy proxy_subnets 2>/dev/null
    ipset destroy proxy_subnets6 2>/dev/null
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    ip6tables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
}

## optimized dns override
start_dnsserver_chnroute() {
    # Remove duplicate options from the base config
    local base_config=$(echo "$dnsmasq_common_config" | sed -E 's/^[[:space:]]*(cache-size|no-resolv|server)[[:space:]]*=.*$//g')
    
    local dnsmasq_config_string="$(cat <<EOT
$base_config
server=$dns_remote
cache-size=10000
no-resolv
conf-file=/etc/ss-tproxy/china-list.conf
conf-file=/etc/ss-tproxy/anti-ad.conf
EOT
)"
    status_dnsmasq_pid=$(dnsmasq --keep-in-foreground --conf-file=- <<<"$dnsmasq_config_string" & echo $!)
    status_chinadns_pid=""
}
HOOKS

# 6. Restart ss-tproxy ecosystem
/usr/local/bin/ss-tproxy restart
