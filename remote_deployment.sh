#!/bin/bash
set -e

# Wait for essential services to settle if they were just synced
systemctl daemon-reload

# 1. Kill existing ss-local on port 10298 to free the port before restart
kill $(netstat -lnpt | grep 10298 | awk '{print $7}' | cut -d'/' -f1) 2>/dev/null || true

# 2. Enable essential systemd services from synced backup
systemctl enable sslocal-dns.service 2>/dev/null || true
systemctl start sslocal-dns.service 2>/dev/null || true

# 3. Restart ss-tproxy ecosystem
/usr/local/bin/ss-tproxy restart
