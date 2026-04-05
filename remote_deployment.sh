#!/bin/bash
set -e

# Wait for essential services to settle if they were just synced
systemctl daemon-reload

# 1. Setup PoLP (Principle of Least Privilege) User
echo "[PoLP] Creating dedicated unprivileged proxy user..."
if ! getent group tproxy >/dev/null; then
    groupadd -r -g 23333 tproxy
fi
if ! getent passwd tproxy >/dev/null; then
    useradd -r -s /bin/false -u 23333 -g tproxy tproxy
fi

# Update ss-tproxy.conf to use the unprivileged user for iptables bypass
sed -i "s/^proxy_procuser=.*/proxy_procuser='tproxy'/" /etc/ss-tproxy/ss-tproxy.conf
sed -i "s/^proxy_procgroup=.*/proxy_procgroup='tproxy'/" /etc/ss-tproxy/ss-tproxy.conf

# 2. Kill existing ss-local on port 10298 to free the port before restart
kill $(netstat -lnpt | grep 10298 | awk '{print $7}' | cut -d'/' -f1) 2>/dev/null || true

# 3. Patch systemd services to run as unprivileged user and apply capabilities
if [ -f /etc/systemd/system/sslocal-dns.service ]; then
    sed -i 's/^User=.*/User=tproxy\nGroup=tproxy\nAmbientCapabilities=CAP_NET_BIND_SERVICE/' /etc/systemd/system/sslocal-dns.service
fi
if [ -f /etc/systemd/system/sslocal-cf.service ]; then
    sed -i 's/^User=.*/User=tproxy\nGroup=tproxy\nAmbientCapabilities=CAP_NET_BIND_SERVICE/' /etc/systemd/system/sslocal-cf.service
fi

# 4. Enable essential systemd services from synced backup
systemctl daemon-reload
systemctl enable sslocal-dns.service 2>/dev/null || true
systemctl start sslocal-dns.service 2>/dev/null || true

# 5. Restart ss-tproxy ecosystem
/usr/local/bin/ss-tproxy restart

# 6. (Optional) Configure Downstream LAN Ports (Persistent)
configure_downstream_lans() {
    local eng_ip="$1"
    echo "[LAN CONFIG] Starting interface enumeration..."

    # Identify Protected Interfaces
    local eng_iface=$(ip -o -4 route get "$eng_ip" 2>/dev/null | awk '{print $5}')
    local ext_iface=$(ip -o -4 route show default 2>/dev/null | awk '{print $5}' | head -n1)

    echo " -> Engineering IFACE: ${eng_iface:-UNKNOWN}"
    echo " -> External IFACE: ${ext_iface:-UNKNOWN}"

    local target_ifaces=()
    if [ -n "$LAN_IFACES" ]; then
        echo " -> Using explicitly defined interfaces: $LAN_IFACES"
        read -a target_ifaces <<< "$LAN_IFACES"
    else
        echo " -> Discovering available interfaces..."
        local all_ifaces=$(ls /sys/class/net | grep -v 'lo')
        local skip="false"
        for iface in $all_ifaces; do
            # If LAN_IFACE_START is set, skip until we find it
            if [ -n "$LAN_IFACE_START" ] && [ "$skip" == "false" ] && [ "$iface" != "$LAN_IFACE_START" ]; then
                continue
            fi

            if [[ "$iface" == "$eng_iface" ]] || [[ "$iface" == "$ext_iface" ]] || [[ "$iface" == "docker"* ]] || [[ "$iface" == "veth"* ]]; then
                echo " -> Skipping protected/virtual interface: $iface"
                continue
            fi
            target_ifaces+=("$iface")
        done
    fi

    if [ ${#target_ifaces[@]} -eq 0 ]; then
        echo "[LAN CONFIG] No candidate interfaces found. Skipping."
        return 0
    fi

    local current_octet=$LAN_START_OCTET
    
    # Initialize Netplan structure
    mkdir -p /etc/netplan
    local netplan_file="/etc/netplan/99-tproxy-lan.yaml"
    echo "network:" > "$netplan_file"
    echo "  version: 2" >> "$netplan_file"
    echo "  renderer: networkd" >> "$netplan_file"
    echo "  ethernets:" >> "$netplan_file"

    for iface in "${target_ifaces[@]}"; do
        local lan_ip="${LAN_BASE_SUBNET}.${current_octet}.1"
        local lan_mask="255.255.255.0"
        local dhcp_start="${LAN_BASE_SUBNET}.${current_octet}.${LAN_DHCP_START}"
        local dhcp_end="${LAN_BASE_SUBNET}.${current_octet}.${LAN_DHCP_END}"

        echo "[LAN CONFIG] Configuring $iface -> $lan_ip/24 (Persistent via Netplan)..."

        # Append to Netplan YAML
        cat <<EOF >> "$netplan_file"
    $iface:
      addresses:
        - $lan_ip/24
      dhcp4: false
      dhcp6: false
EOF

        # Add DHCP range to dnsmasq
        local dhcp_conf="/etc/dnsmasq.d/dhcp_$iface.conf"
        mkdir -p /etc/dnsmasq.d
        cat <<EOF > "$dhcp_conf"
interface=$iface
dhcp-range=$dhcp_start,$dhcp_end,$LAN_DHCP_LEASE
dhcp-option=option:router,$lan_ip
dhcp-option=option:dns-server,$lan_ip
EOF

        ((current_octet++))
    done

    # Apply Netplan configuration
    echo "[LAN CONFIG] Applying Netplan configuration..."
    netplan apply 2>/dev/null || systemctl restart systemd-networkd

    # Ensure dnsmasq includes the new dhcp configs
    if ! grep -q "conf-dir=/etc/dnsmasq.d" /etc/ss-tproxy/ss-tproxy.conf; then
        sed -i "/^dnsmasq_conf_dir=/s/)/ \/etc\/dnsmasq.d)/" /etc/ss-tproxy/ss-tproxy.conf
    fi

    echo "[LAN CONFIG] Finished. Restarting dnsmasq/ss-tproxy to apply DHCP changes."
    systemctl restart dnsmasq 2>/dev/null || /usr/local/bin/ss-tproxy restart
}

if [ "$ENABLE_LAN_CONFIG" == "true" ]; then
    configure_downstream_lans "$ENG_IP"
fi

