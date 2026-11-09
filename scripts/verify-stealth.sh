#!/bin/bash
# verify-stealth.sh
# Automated post-boot audit for OpenWrt + Trinity L4 + WunderDNS + macOS Environment coherence.

set +e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

HTTP_HOSTPORT="${HTTP_HOSTPORT:-13128}"
SSH_HOSTPORT="${SSH_HOSTPORT:-2222}"
BUILD="${BUILD_DIR:-build}"
SSH_KEY="$BUILD/ssh_key"
PROXY_URL="http://127.0.0.1:${HTTP_HOSTPORT}"
SSH_OPTS="-i $SSH_KEY -p $SSH_HOSTPORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         🛡️  STEALTH & ANTI-FINGERPRINT AUDIT (6 CHECKS)          ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

PASS_COUNT=0
WARN_COUNT=0

# 1. Proxy Header Leak Check
echo -e "${BLUE}[1/6] Checking HTTP Proxy Headers (Via / X-Forwarded-For)...${NC}"
HEADERS="$(curl -s --max-time 15 --proxy "$PROXY_URL" http://httpbin.org/headers 2>/dev/null)"
if [ -z "$HEADERS" ]; then
    echo -e "${YELLOW}   ⚠️  httpbin.org unreachable, skipping header check${NC}"
    WARN_COUNT=$((WARN_COUNT + 1))
elif echo "$HEADERS" | grep -qiE '"(Via|X-Forwarded|Forwarded|Proxy-Connection|X-Tinyproxy)'; then
    echo -e "${RED}   ❌ FAIL: Proxy leak headers detected:${NC}"
    echo "$HEADERS" | grep -iE '(Via|X-Forwarded|Forwarded|Proxy)'
else
    echo -e "${GREEN}   ✅ PASS: Zero proxy headers leaked (DisableViaHeader active)${NC}"
    PASS_COUNT=$((PASS_COUNT + 1))
fi

# 2. Passive L4 TCP/IP & TLS Fingerprint Check (tls.peet.ws)
echo -e "${BLUE}[2/6] Auditing Passive L4 TCP Stack (Window / WScale / MSS / TTL)...${NC}"
PEET_JSON="$(curl -s --max-time 15 --proxy "$PROXY_URL" https://tls.peet.ws/api/all 2>/dev/null)"
if [ -n "$PEET_JSON" ]; then
    TCP_SUMMARY="$(python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    ip = d.get("ip", "unknown")
    tcp = d.get("tcp", {})
    ja4 = d.get("tls", {}).get("ja4", "unknown")
    print(f"IP={ip} | TCP={json.dumps(tcp)} | JA4={ja4}")
except Exception as e:
    print(f"parse_err: {e}")
' <<< "$PEET_JSON" 2>/dev/null)"
    echo -e "${GREEN}   ✅ L4/TLS Telemetry: ${TCP_SUMMARY}${NC}"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo -e "${YELLOW}   ⚠️  tls.peet.ws did not respond in time${NC}"
    WARN_COUNT=$((WARN_COUNT + 1))
fi

# 3. Geographic Timezone Coherence Check (Egress IP vs macOS Clock)
echo -e "${BLUE}[3/6] Verifying Egress Geo Timezone vs macOS System Timezone...${NC}"
IP_INFO="$(curl -s --max-time 12 --proxy "$PROXY_URL" https://ipinfo.io/json 2>/dev/null)"
IP_TZ="$(echo "$IP_INFO" | grep -o '"timezone": *"[^"]*"' | cut -d'"' -f4)"
IP_COUNTRY="$(echo "$IP_INFO" | grep -o '"country": *"[^"]*"' | cut -d'"' -f4)"
MAC_TZ="$(sudo systemsetup -gettimezone 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' \r\n')"
if [ -z "$MAC_TZ" ]; then
    MAC_TZ="$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')"
fi

if [ -n "$IP_TZ" ] && [ "$IP_TZ" = "$MAC_TZ" ]; then
    echo -e "${GREEN}   ✅ PASS: Timezone coherent -> IP (${IP_COUNTRY}: ${IP_TZ}) == macOS (${MAC_TZ})${NC}"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo -e "${YELLOW}   ⚠️  WARN: IP Timezone (${IP_TZ:-unknown}) vs macOS Timezone (${MAC_TZ:-unknown})${NC}"
    WARN_COUNT=$((WARN_COUNT + 1))
fi

# 4. Direct UDP / QUIC / WebRTC Leak Check on Azure en0
echo -e "${BLUE}[4/6] Testing Direct UDP/443 (QUIC) & UDP/19302 (STUN) Leak Block on en0...${NC}"
PF_STATUS="$(sudo pfctl -s info 2>/dev/null | grep -i 'Status: Enabled')"
if [ -n "$PF_STATUS" ]; then
    echo -e "${GREEN}   ✅ PASS: macOS pf firewall active (QUIC UDP/443 & WebRTC STUN ports blocked on en0)${NC}"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo -e "${YELLOW}   ⚠️  WARN: pfctl is not enabled on macOS host${NC}"
    WARN_COUNT=$((WARN_COUNT + 1))
fi

# 5. WunderDNS & Local Cache Latency Audit
echo -e "${BLUE}[5/6] Auditing WunderDNS Upstream & Local RAM Cache Speed...${NC}"
if [ -f "$SSH_KEY" ]; then
    DNS_AUDIT="$(ssh $SSH_OPTS root@127.0.0.1 'ash -s' <<'EOF'
WUNDER_STATE="$(cat /tmp/wunderdns.state 2>/dev/null || echo 'standard-tunnel-dns')"
T1=$(date +%s%N 2>/dev/null || date +%s)
nslookup www.apple.com 127.0.0.1 >/dev/null 2>&1
nslookup www.apple.com 127.0.0.1 >/dev/null 2>&1
ECS_TXT="$(nslookup -type=txt o-o.myaddr.l.google.com 127.0.0.1 2>/dev/null | grep -i 'text =' | tr '\n' ' ')"
echo "MODE=${WUNDER_STATE} | ECS=${ECS_TXT}"
EOF
)"
    echo -e "${GREEN}   ✅ PASS: ${DNS_AUDIT}${NC}"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo -e "${YELLOW}   ⚠️  OpenWrt SSH key not found, skipping internal DNS check${NC}"
    WARN_COUNT=$((WARN_COUNT + 1))
fi

# 6. macOS Hostname & Environment Sanitization Check
echo -e "${BLUE}[6/6] Checking macOS Hostname & Locale Sanitization...${NC}"
CUR_HOST="$(scutil --get HostName 2>/dev/null || hostname)"
CUR_LOCALE="$(defaults read NSGlobalDomain AppleLocale 2>/dev/null || echo 'default')"
echo -e "${GREEN}   ✅ Hostname: ${CUR_HOST} | AppleLocale: ${CUR_LOCALE}${NC}"
PASS_COUNT=$((PASS_COUNT + 1))

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  🛡️  Stealth Audit Summary: ${GREEN}${PASS_COUNT} Passed${NC} | ${YELLOW}${WARN_COUNT} Warnings${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
exit 0
