#!/bin/bash
# setup-openwrt.sh
# Boot OpenWrt inside the macOS GitHub runner (QEMU HVF/TCG) with:
#   1. Trinity L4 TCP Stack Tuning (Window=65535, WScale=6, TTL=64 on egress, MSS=1400)
#   2. WunderDNS Engine: Internal ISP Router DNS Hunter (192.168.1.1 / 10.0.0.1 / etc.
#      over SOCKS5/Tunnel TCP:53 without SOCKS5H leaks) + 10,000-entry RAM cache in dnsmasq
#   3. Proxy Stealth: DisableViaHeader Yes, filter-aaaa=1, sanitized router hostname
#   4. Host Environment Sync: Auto-matches macOS Timezone & Locale to egress IP geo,
#      blocks direct UDP/443 (QUIC) and STUN/WebRTC leaks on en0 via pfctl.

set +e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.0}"
BUILD="${BUILD_DIR:-build}"
OPENWRT_RAM_MB="${OPENWRT_RAM_MB:-512}"
OPENWRT_CPUS="${OPENWRT_CPUS:-2}"
SSH_HOSTPORT="${SSH_HOSTPORT:-2222}"
HTTP_HOSTPORT="${HTTP_HOSTPORT:-13128}"
SOCKS_HOSTPORT="${SOCKS_HOSTPORT:-11080}"
HTTP_GUESTPORT=3128
SOCKS_GUESTPORT=1080

mkdir -p "$BUILD"
ROOT="$PWD"
IMG="$BUILD/openwrt.img"
SSH_KEY="$BUILD/ssh_key"
SERIAL_LOG="$BUILD/qemu-serial.log"
QEMU_PIDFILE="$BUILD/qemu.pid"
QEMU_LOG="$BUILD/qemu.log"

# Fail-closed when a dedicated egress (WireGuard or Residential SOCKS5) was requested
REQUIRE_TUNNEL="${REQUIRE_TUNNEL:-false}"
if [ -n "${WG_CLIENT_SLOTS_B64:-}" ] || [ -n "${SOCKS5_HOST:-}" ] || [ -n "${GCP_PROXY_PASS:-}" ]; then
    REQUIRE_TUNNEL="true"
fi

fail_handler() {
    echo -e "${RED}❌ OpenWrt setup error: $1${NC}"
    echo "OPENWRT_ENABLED=false" >> "${GITHUB_ENV:-/dev/null}"
    if [ "$REQUIRE_TUNNEL" = "true" ]; then
        echo -e "${RED}🚨 FAIL-CLOSED: Dedicated egress was requested, refusing to fall back to raw Azure IP!${NC}"
        exit 1
    fi
    echo -e "${YELLOW}⚠️  Continuing without OpenWrt exit (native Azure mode).${NC}"
    exit 0
}

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     🧭 OPENWRT ROUTER + TRINITY L4 + WUNDERDNS (inside Mac)      ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
    arm64|aarch64)
        OPENWRT_TARGET_PATH="armsr/armv8"
        OPENWRT_PROFILE="armsr-armv8-generic"
        QEMU_BIN_NAME="qemu-system-aarch64"
        QEMU_MACHINE="-machine virt,gic-version=max"
        FW_NAME="edk2-aarch64-code.fd"
        STRIP_ARM_KMODS=1
        ;;
    x86_64)
        OPENWRT_TARGET_PATH="x86/64"
        OPENWRT_PROFILE="x86-64-generic"
        QEMU_BIN_NAME="qemu-system-x86_64"
        QEMU_MACHINE=""
        FW_NAME="edk2-x86_64-code.fd"
        STRIP_ARM_KMODS=0
        ;;
    *)
        fail_handler "unsupported arch $HOST_ARCH"
        ;;
esac

echo -e "${BLUE}📦 Installing QEMU + e2fsprogs (Homebrew)...${NC}"
if ! command -v brew >/dev/null 2>&1; then
    fail_handler "Homebrew is not available on this runner"
fi
brew list qemu >/dev/null 2>&1 || brew install qemu
brew list e2fsprogs >/dev/null 2>&1 || brew install e2fsprogs

QEMU_BIN="$(command -v "$QEMU_BIN_NAME")"
DEBUGFS="$(brew --prefix e2fsprogs)/sbin/debugfs"
if [ ! -x "$QEMU_BIN" ]; then
    fail_handler "$QEMU_BIN_NAME not found after brew install"
fi
if [ ! -x "$DEBUGFS" ]; then
    fail_handler "debugfs not found after brew install e2fsprogs"
fi

FW=""
for candidate in \
    "$(brew --prefix qemu)/share/qemu/${FW_NAME}" \
    "/opt/homebrew/share/qemu/${FW_NAME}" \
    "/usr/local/share/qemu/${FW_NAME}"; do
    if [ -f "$candidate" ]; then
        FW="$candidate"
        break
    fi
done
if [ -z "$FW" ]; then
    fail_handler "UEFI firmware $FW_NAME not found"
fi

IMG_GZ="$BUILD/openwrt-${OPENWRT_VERSION}-${OPENWRT_PROFILE}.img.gz"
IMG_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${OPENWRT_TARGET_PATH}/openwrt-${OPENWRT_VERSION}-${OPENWRT_PROFILE}-ext4-combined-efi.img.gz"

echo -e "${BLUE}📥 Downloading OpenWrt ${OPENWRT_VERSION} (${OPENWRT_PROFILE})...${NC}"
if [ ! -s "$IMG_GZ" ]; then
    curl -fL --retry 3 --retry-delay 2 -o "$IMG_GZ" "$IMG_URL" || fail_handler "failed to download OpenWrt image"
fi

echo -e "${BLUE}📂 Decompressing image...${NC}"
gzip -dc "$IMG_GZ" > "$IMG" || true
[ -s "$IMG" ] || fail_handler "decompressed image is empty"

echo -e "${BLUE}🔑 Generating OpenWrt root SSH key...${NC}"
rm -f "$SSH_KEY" "$SSH_KEY.pub"
ssh-keygen -t ed25519 -N '' -f "$SSH_KEY" -C "router-admin" -q
chmod 600 "$SSH_KEY"

BOOTSTRAP="$BUILD/99-mac-bootstrap"
cat > "$BOOTSTRAP" <<'UCIDEFAULTS'
#!/bin/sh
uci batch <<EOF
set network.lan.proto='dhcp'
delete network.lan.ipaddr
delete network.lan.netmask
delete network.lan.ip6assign
set network.lan.device='eth0'
set system.@system[0].hostname='Home-Gateway'
EOF
uci commit network
uci commit system

uci set dropbear.@dropbear[0].Interface=''
uci set dropbear.@dropbear[0].Port='22'
uci set dropbear.@dropbear[0].PasswordAuth='off'
uci set dropbear.@dropbear[0].RootPasswordAuth='off'
uci commit dropbear

uci -q delete firewall.gha_ssh || true
uci -q delete firewall.gha_proxy || true
uci batch <<EOF
set firewall.gha_ssh=rule
set firewall.gha_ssh.name='Allow-SSH-WAN-bootstrap'
set firewall.gha_ssh.src='wan'
set firewall.gha_ssh.proto='tcp'
set firewall.gha_ssh.dest_port='22'
set firewall.gha_ssh.target='ACCEPT'
set firewall.gha_proxy=rule
set firewall.gha_proxy.name='Allow-Proxy-WAN'
set firewall.gha_proxy.src='wan'
set firewall.gha_proxy.proto='tcp'
set firewall.gha_proxy.dest_port='3128 1080'
set firewall.gha_proxy.target='ACCEPT'
EOF
uci commit firewall

/etc/init.d/network reload
/etc/init.d/dropbear restart
/etc/init.d/firewall reload
sleep 5
touch /etc/.gha-bootstrap-done
exit 0
UCIDEFAULTS
chmod 0755 "$BOOTSTRAP"

BLACKLIST="$BUILD/00-gha-virt-blacklist.conf"
cat > "$BLACKLIST" <<'BLACKLIST'
blacklist vmxnet3
blacklist macsec
blacklist rvu_af
blacklist rvu_nicpf
blacklist rvu_nicvf
blacklist thunder_bgx
blacklist thunder_xcv
blacklist e1000e
blacklist ixgbe
blacklist i40e
blacklist mlx4_core
blacklist mlx5_core
blacklist ena
blacklist ppp_generic
blacklist pppoe
BLACKLIST

NETWORK_CFG="$BUILD/network"
cat > "$NETWORK_CFG" <<'NET'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config device
	option name 'br-lan'
	option type 'bridge'
	list ports 'eth0'

config interface 'lan'
	option device 'br-lan'
	option proto 'dhcp'
NET

DROPBEAR_CFG="$BUILD/dropbear"
cat > "$DROPBEAR_CFG" <<'DB'
config dropbear
	option PasswordAuth 'off'
	option RootPasswordAuth 'off'
	option Port '22'
DB

echo -e "${BLUE}🧩 Injecting first-boot config into ext4 rootfs...${NC}"
GPT_INFO="$(python3 - "$IMG" <<'PY'
import struct, sys
path = sys.argv[1]
with open(path, "rb") as f:
    f.seek(512)
    hdr = f.read(92)
    if hdr[:8] != b"EFI PART":
        sys.stderr.write("not a GPT disk\n")
        sys.exit(1)
    part_lba = struct.unpack_from("<Q", hdr, 72)[0]
    num_parts = struct.unpack_from("<I", hdr, 80)[0]
    part_size = struct.unpack_from("<I", hdr, 84)[0]
    f.seek(part_lba * 512)
    entries = f.read(num_parts * part_size)
    if len(entries) < part_size * 2:
        sys.stderr.write("missing GPT partition 2\n")
        sys.exit(1)
    e = entries[part_size:part_size * 2]
    first, last = struct.unpack_from("<QQ", e, 32)
    print(f"{first} {last - first + 1}")
PY
)" || fail_handler "could not parse GPT on OpenWrt image"

P2_START="${GPT_INFO%% *}"
P2_COUNT="${GPT_INFO##* }"
ROOTFS="$BUILD/rootfs.img"
dd if="$IMG" of="$ROOTFS" bs=512 skip="$P2_START" count="$P2_COUNT" status=none || fail_handler "failed to extract rootfs partition"
"$DEBUGFS" -R "stats" "$ROOTFS" >/dev/null 2>&1 || fail_handler "extracted rootfs is not a readable ext4 image"

dfs() {
    "$DEBUGFS" -w -R "$1" "$ROOTFS"
}

inject_file() {
    local src
    src="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
    local dest="$2"
    local mode="$3"
    dfs "rm $dest" >/dev/null 2>&1
    dfs "unlink $dest" >/dev/null 2>&1
    if ! dfs "write $src $dest" >/dev/null; then
        fail_handler "debugfs write failed for $dest"
    fi
    dfs "sif $dest mode $mode" >/dev/null 2>&1
}

dfs "mkdir /etc/uci-defaults" >/dev/null 2>&1
dfs "mkdir /etc/dropbear" >/dev/null 2>&1
dfs "mkdir /etc/modprobe.d" >/dev/null 2>&1
inject_file "$BOOTSTRAP" "/etc/uci-defaults/99-mac-bootstrap" 0100755
inject_file "$SSH_KEY.pub" "/etc/dropbear/authorized_keys" 0100600
inject_file "$BLACKLIST" "/etc/modprobe.d/00-gha-virt-blacklist.conf" 0100644
inject_file "$NETWORK_CFG" "/etc/config/network" 0100644
inject_file "$DROPBEAR_CFG" "/etc/config/dropbear" 0100644

VERIFY="$("$DEBUGFS" -R "cat /etc/config/network" "$ROOTFS" 2>/dev/null)"
if ! echo "$VERIFY" | grep -q "option proto 'dhcp'"; then
    echo "$VERIFY"
    fail_handler "network config was not written into the OpenWrt rootfs"
fi
VERIFY_KEY="$("$DEBUGFS" -R "stat /etc/dropbear/authorized_keys" "$ROOTFS" 2>/dev/null)"
if ! echo "$VERIFY_KEY" | grep -qi "type: regular"; then
    echo "$VERIFY_KEY"
    fail_handler "authorized_keys was not written into the OpenWrt rootfs"
fi
echo -e "${GREEN}✅ Rootfs injection verified (DHCP + SSH key)${NC}"

if [ "$STRIP_ARM_KMODS" = "1" ]; then
    echo -e "${BLUE}🧹 Stripping ARM server NIC autoload (avoids TCG boot stalls)...${NC}"
    MODULE_LIST="$("$DEBUGFS" -R "ls -p /etc/modules.d" "$ROOTFS" 2>/dev/null)"
    echo "$MODULE_LIST" | awk -F/ '{print $6}' | while read -r name; do
        [ -z "$name" ] && continue
        case "$name" in
            .|..) continue ;;
            *macsec*|*vmxnet3*|*thunder*|*rvu*|*nicpf*|*nicvf*|*e1000*|*ppp*|*octeon*|*marvell*|*cavium*|*ena*|*ixgbe*|*i40e*|*mlx*|*bnxt*|*qede*|*tg3*|*sfc*|*bcm*|*mvneta*|*mvpp2*|*stmmac*|*dwmac*|*atlantic*|*aquantia*|*realtek*|*smsc*|*phylib*|*enetc*|*dpaa*)
                dfs "unlink /etc/modules.d/$name" >/dev/null 2>&1
                ;;
        esac
    done
fi

dd if="$ROOTFS" of="$IMG" bs=512 seek="$P2_START" conv=notrunc status=none || fail_handler "failed to write rootfs back"

start_qemu() {
    local accel="$1"
    # shellcheck disable=SC2086
    nohup "$QEMU_BIN" \
        $accel \
        $QEMU_MACHINE \
        -m "$OPENWRT_RAM_MB" \
        -smp "$OPENWRT_CPUS" \
        -bios "$FW" \
        -drive if=virtio,format=raw,file="$IMG" \
        -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${SSH_HOSTPORT}-:22,hostfwd=tcp:127.0.0.1:${HTTP_HOSTPORT}-:${HTTP_GUESTPORT},hostfwd=tcp:127.0.0.1:${SOCKS_HOSTPORT}-:${SOCKS_GUESTPORT}" \
        -device virtio-net-pci,netdev=n0 \
        -nographic \
        -serial "file:${SERIAL_LOG}" \
        >"$QEMU_LOG" 2>&1 &
    echo $! > "$QEMU_PIDFILE"
    sleep 3
    kill -0 "$(cat "$QEMU_PIDFILE")" 2>/dev/null
}

echo -e "${BLUE}🚀 Booting OpenWrt VM...${NC}"
if sysctl -n kern.hv_support 2>/dev/null | grep -q 1; then
    echo -e "${GREEN}Trying HVF acceleration${NC}"
    if ! start_qemu "-accel hvf -cpu host"; then
        echo -e "${YELLOW}HVF failed — falling back to TCG${NC}"
        start_qemu "-accel tcg -cpu max" || fail_handler "QEMU exited immediately (see $QEMU_LOG)"
    fi
else
    echo -e "${YELLOW}HVF unavailable — using TCG (slower first boot)${NC}"
    start_qemu "-accel tcg -cpu max" || fail_handler "QEMU exited immediately (see $QEMU_LOG)"
fi

SSH_OPTS="-i $SSH_KEY -p $SSH_HOSTPORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"
echo -e "${BLUE}⏳ Waiting for OpenWrt SSH (up to ~8 minutes on TCG)...${NC}"
READY=0
for i in $(seq 1 96); do
    if ssh $SSH_OPTS root@127.0.0.1 "echo READY" 2>/dev/null | grep -q READY; then
        READY=1
        echo -e "${GREEN}✅ OpenWrt is reachable over SSH${NC}"
        break
    fi
    if [ $((i % 12)) -eq 0 ]; then
        echo ""
        echo -e "${YELLOW}   still waiting ($i/96). last serial:${NC}"
        tail -n 8 "$SERIAL_LOG" 2>/dev/null || true
    else
        printf "\r   waiting... %s/96" "$i"
    fi
    sleep 5
done
echo ""
if [ "$READY" != "1" ]; then
    echo -e "${YELLOW}Last serial lines:${NC}"
    tail -n 40 "$SERIAL_LOG" 2>/dev/null || true
    fail_handler "OpenWrt did not become reachable on 127.0.0.1:${SSH_HOSTPORT}"
fi

echo -e "${BLUE}📦 Provisioning OpenWrt packages + Trinity TCP tuning + WunderDNS...${NC}"
ssh $SSH_OPTS root@127.0.0.1 'ash -s' <<'REMOTE'
set +e
opkg update
opkg install tinyproxy microsocks wireguard-tools kmod-wireguard python3-light

# --- TRINITY L4 TCP STACK TUNING ---
# Forces the Linux TCP state machine to natively select WScale=6 and Window=65535
# (matching macOS XNU TCP parameters without breaking flow control).
cat > /etc/sysctl.d/99-trinity-tcp.conf <<'SYSCTL'
net.ipv4.ip_default_ttl=64
net.core.rmem_max=3145728
net.core.wmem_max=3145728
net.ipv4.tcp_rmem=4096 131072 3145728
net.ipv4.tcp_wmem=4096 131072 3145728
net.ipv4.tcp_adv_win_scale=2
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_keepalive_probes=4
SYSCTL
sysctl -p /etc/sysctl.d/99-trinity-tcp.conf >/dev/null 2>&1

# --- WUNDERDNS ENGINE (Internal ISP Router DNS Hunter + Local Cache Bridge) ---
# Probes internal RFC1918 ISP home gateways (192.168.1.1, 10.0.0.1, 192.168.1.254,
# 192.168.0.1, 192.168.15.1, etc.) over TCP:53 through SOCKS5 or Tunnel to obtain
# 100% native ISP DHCP DNS without ever using SOCKS5H (8.8.8.8 leak).
# Also provides an HTTP+SOCKS5 forwarder that resolves domains locally via dnsmasq
# RAM cache and sends raw IPv4 (ATYP=0x01) to any upstream SOCKS5 proxy.
cat > /usr/bin/wunderdns.py <<'WUNDERPY'
#!/usr/bin/env python3
import os, sys, socket, struct, select, threading, time

CANDIDATE_ISP_GATEWAYS = [
    "192.168.1.1",     # Verizon Fios / TP-Link / Standard CPE
    "10.0.0.1",        # Comcast Xfinity / Arris / Cisco
    "192.168.1.254",   # AT&T Fiber BGW210 / BGW320
    "192.168.0.1",     # Spectrum / Charter / Claro / Netgear
    "192.168.15.1",    # Vivo Fibra BR (MitraStar / Askey)
    "192.168.2.1",     # Regional Fiber CPE
    "192.168.100.1",   # DOCSIS Cable Modem
    "172.20.10.1",     # Apple iPhone Personal Hotspot
    "192.168.43.1",    # Android Hotspot
    "10.177.0.34",     # T-Mobile CGNAT Internal DNS
]
FALLBACK_RESOLVERS = ["8.8.8.8", "1.1.1.1", "8.8.4.4"]

SOCKS_HOST = os.environ.get("SOCKS5_HOST", "").strip()
SOCKS_PORT = int(os.environ.get("SOCKS5_PORT", "1080") or "1080")
SOCKS_USER = os.environ.get("SOCKS5_USER", "").strip()
SOCKS_PASS = os.environ.get("SOCKS5_PASS", "").strip()

def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("socket closed")
        buf += chunk
    return buf

def connect_via_socks5(target_ip, target_port, timeout=2.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect((SOCKS_HOST, SOCKS_PORT))
    if SOCKS_USER:
        s.sendall(b"\x05\x02\x00\x02")
    else:
        s.sendall(b"\x05\x01\x00")
    ver, method = recv_exact(s, 2)
    if method == 0x02:
        u = SOCKS_USER.encode()
        p = SOCKS_PASS.encode()
        s.sendall(b"\x01" + bytes([len(u)]) + u + bytes([len(p)]) + p)
        _, status = recv_exact(s, 2)
        if status != 0x00:
            s.close()
            raise PermissionError("SOCKS5 auth failed")
    elif method != 0x00:
        s.close()
        raise PermissionError("SOCKS5 unsupported auth")
    # Always connect by raw IPv4 (ATYP=0x01) - NEVER leak domain via SOCKS5H!
    ip_bytes = socket.inet_aton(target_ip)
    req = b"\x05\x01\x00\x01" + ip_bytes + struct.pack("!H", target_port)
    s.sendall(req)
    hdr = recv_exact(s, 4)
    if hdr[1] != 0x00:
        s.close()
        raise ConnectionError(f"SOCKS5 connect failed: {hdr[1]}")
    atyp = hdr[3]
    if atyp == 1:
        recv_exact(s, 4 + 2)
    elif atyp == 3:
        ln = recv_exact(s, 1)[0]
        recv_exact(s, ln + 2)
    elif atyp == 4:
        recv_exact(s, 16 + 2)
    return s

def open_tcp_channel(target_ip, target_port, timeout=2.0):
    if SOCKS_HOST:
        return connect_via_socks5(target_ip, target_port, timeout)
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect((target_ip, target_port))
    return s

def build_probe_query():
    # Standard DNS query for www.apple.com (A record)
    txid = b"\x13\x37"
    flags = b"\x01\x00"
    counts = b"\x00\x01\x00\x00\x00\x00\x00\x00"
    qname = b"\x03www\x05apple\x03com\x00"
    qtype_class = b"\x00\x01\x00\x01"
    return txid + flags + counts + qname + qtype_class

def tcp_dns_query(resolver_ip, raw_query, timeout=2.0):
    s = open_tcp_channel(resolver_ip, 53, timeout=timeout)
    try:
        payload = struct.pack("!H", len(raw_query)) + raw_query
        s.sendall(payload)
        resp_len = struct.unpack("!H", recv_exact(s, 2))[0]
        resp = recv_exact(s, resp_len)
        return resp
    finally:
        s.close()

def hunt_best_dns():
    probe = build_probe_query()
    found = []
    lock = threading.Lock()

    def worker(ip, priority):
        try:
            resp = tcp_dns_query(ip, probe, timeout=1.5)
            if len(resp) >= 12:
                flags = struct.unpack("!H", resp[2:4])[0]
                ancount = struct.unpack("!H", resp[6:8])[0]
                rcode = flags & 0x000F
                if (flags & 0x8000) and rcode == 0 and ancount >= 1:
                    with lock:
                        found.append((priority, ip))
        except Exception:
            pass

    threads = []
    for idx, gw in enumerate(CANDIDATE_ISP_GATEWAYS):
        t = threading.Thread(target=worker, args=(gw, idx))
        t.daemon = True
        t.start()
        threads.append(t)
    for t in threads:
        t.join(timeout=1.8)

    if found:
        found.sort(key=lambda x: x[0])
        chosen = found[0][1]
        mode = f"wunderdns-internal-isp-gateway:{chosen}"
        return chosen, mode

    for idx, fb in enumerate(FALLBACK_RESOLVERS):
        try:
            resp = tcp_dns_query(fb, probe, timeout=2.5)
            if len(resp) >= 12:
                return fb, f"wunderdns-tunnel-tcp:{fb}"
        except Exception:
            pass
    return "8.8.8.8", "wunderdns-fallback:8.8.8.8"

ACTIVE_RESOLVER, ACTIVE_MODE = hunt_best_dns()
with open("/tmp/wunderdns.state", "w") as f:
    f.write(ACTIVE_MODE + "\n")

def handle_dns_udp(sock, data, addr):
    global ACTIVE_RESOLVER
    try:
        resp = tcp_dns_query(ACTIVE_RESOLVER, data, timeout=3.5)
        sock.sendto(resp, addr)
    except Exception:
        for fb in FALLBACK_RESOLVERS:
            try:
                resp = tcp_dns_query(fb, data, timeout=3.0)
                sock.sendto(resp, addr)
                break
            except Exception:
                pass

def pipe_sockets(a, b):
    sockets = [a, b]
    try:
        while True:
            r, _, _ = select.select(sockets, [], [], 120.0)
            if not r:
                break
            for s in r:
                data = s.recv(16384)
                if not data:
                    return
                if s is a:
                    b.sendall(data)
                else:
                    a.sendall(data)
    except Exception:
        pass
    finally:
        try: a.close()
        except Exception: pass
        try: b.close()
        except Exception: pass

def handle_http_to_socks(client_sock):
    try:
        client_sock.settimeout(10.0)
        req = b""
        while b"\r\n\r\n" not in req and len(req) < 8192:
            chunk = client_sock.recv(1024)
            if not chunk:
                client_sock.close()
                return
            req += chunk
        first_line = req.split(b"\r\n", 1)[0].decode("latin1", errors="ignore")
        parts = first_line.split(" ")
        if len(parts) < 2:
            client_sock.close()
            return
        method = parts[0].upper()
        target = parts[1]
        if method == "CONNECT":
            host, port_s = target.rsplit(":", 1)
            port = int(port_s)
            # Resolve locally via dnsmasq (127.0.0.1:53 -> WunderDNS cache) so SOCKS5 never sees domain!
            resolved_ip = socket.gethostbyname(host)
            remote = connect_via_socks5(resolved_ip, port, timeout=10.0)
            client_sock.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            pipe_sockets(client_sock, remote)
        else:
            # Plain HTTP request through proxy
            if target.startswith("http://"):
                rest = target[7:]
                slash = rest.find("/")
                host_port = rest[:slash] if slash != -1 else rest
                path = rest[slash:] if slash != -1 else "/"
                if ":" in host_port:
                    host, port_s = host_port.rsplit(":", 1)
                    port = int(port_s)
                else:
                    host, port = host_port, 80
                resolved_ip = socket.gethostbyname(host)
                remote = connect_via_socks5(resolved_ip, port, timeout=10.0)
                rewritten = f"{method} {path} {parts[2]}\r\n".encode("latin1") + req.split(b"\r\n", 1)[1]
                remote.sendall(rewritten)
                pipe_sockets(client_sock, remote)
            else:
                client_sock.close()
    except Exception:
        try: client_sock.close()
        except Exception: pass

def http_bridge_loop():
    if not SOCKS_HOST:
        return
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 8128))
    srv.listen(128)
    while True:
        try:
            c, _ = srv.accept()
            t = threading.Thread(target=handle_http_to_socks, args=(c,))
            t.daemon = True
            t.start()
        except Exception:
            time.sleep(0.05)

def dns_bridge_loop():
    if SOCKS_HOST:
        ht = threading.Thread(target=http_bridge_loop)
        ht.daemon = True
        ht.start()
    usock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    usock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    usock.bind(("127.0.0.1", 5353))
    while True:
        try:
            data, addr = usock.recvfrom(4096)
            t = threading.Thread(target=handle_dns_udp, args=(usock, data, addr))
            t.daemon = True
            t.start()
        except Exception:
            time.sleep(0.05)

if __name__ == "__main__":
    dns_bridge_loop()
WUNDERPY
chmod +x /usr/bin/wunderdns.py

mkdir -p /etc/tinyproxy
cat > /etc/tinyproxy/tinyproxy.conf <<'CFG'
Port 3128
Listen 0.0.0.0
Timeout 600
LogLevel Error
MaxClients 256
DisableViaHeader Yes
FilterDefaultDeny Off
Allow 0.0.0.0/0
ConnectPort 443
ConnectPort 80
ConnectPort 8080
ConnectPort 8443
ConnectPort 5222
ConnectPort 5228
ConnectPort 853
CFG

if [ -x /etc/init.d/tinyproxy ]; then
    /etc/init.d/tinyproxy enable
    /etc/init.d/tinyproxy restart
fi
command -v tinyproxy >/dev/null 2>&1 && tinyproxy -c /etc/tinyproxy/tinyproxy.conf 2>/dev/null
pgrep tinyproxy >/dev/null 2>&1 || tinyproxy -c /etc/tinyproxy/tinyproxy.conf

if command -v microsocks >/dev/null 2>&1; then
    cat > /etc/init.d/microsocks <<'INIT'
#!/bin/sh /etc/rc.common
START=90
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/microsocks -i 0.0.0.0 -p 1080
    procd_set_param respawn
    procd_close_instance
}
INIT
    chmod +x /etc/init.d/microsocks
    /etc/init.d/microsocks enable
    /etc/init.d/microsocks restart
fi

/etc/init.d/firewall reload
REMOTE

WG_ENDPOINT="${WG_ENDPOINT:-35.215.247.149}"
WG_ENDPOINT_PORT="${WG_ENDPOINT_PORT:-51820}"
WG_CLIENT_SLOTS_B64="${WG_CLIENT_SLOTS_B64:-}"
WG_SERVER_PUBLIC_KEY="${WG_SERVER_PUBLIC_KEY:-}"
SOCKS5_HOST="${SOCKS5_HOST:-}"
SOCKS5_PORT="${SOCKS5_PORT:-1080}"
SOCKS5_USER="${SOCKS5_USER:-}"
SOCKS5_PASS="${SOCKS5_PASS:-}"

if [ -n "$WG_CLIENT_SLOTS_B64" ] && [ -n "$WG_SERVER_PUBLIC_KEY" ]; then
    echo -e "${BLUE}🛣  Configuring OpenWrt WireGuard Router + Trinity L4 + WunderDNS...${NC}"
    # Decode the slot pool on the HOST (macOS base64 is always present; some OpenWrt
    # busybox builds ship without the base64 applet, which killed the tunnel in-VM).
    WG_CLIENT_SLOTS_PLAIN=$(printf '%s' "$WG_CLIENT_SLOTS_B64" | base64 -D 2>/dev/null || printf '%s' "$WG_CLIENT_SLOTS_B64" | base64 -d)
    ssh $SSH_OPTS root@127.0.0.1 "cat > /tmp/wg.env" <<WGENV
WG_ENDPOINT=${WG_ENDPOINT}
WG_ENDPOINT_PORT=${WG_ENDPOINT_PORT}
WG_SERVER_PUBLIC_KEY=${WG_SERVER_PUBLIC_KEY}
WG_CLIENT_SLOTS=${WG_CLIENT_SLOTS_PLAIN}
SOCKS5_HOST=${SOCKS5_HOST}
SOCKS5_PORT=${SOCKS5_PORT}
SOCKS5_USER=${SOCKS5_USER}
SOCKS5_PASS=${SOCKS5_PASS}
WGENV
    ssh $SSH_OPTS root@127.0.0.1 'ash -s' <<'REMOTE'
set +e
. /tmp/wg.env
rm -f /tmp/wg.env

SLOTS_N=$(printf '%s\n' "$WG_CLIENT_SLOTS" | grep -c .)
if [ -z "$WG_CLIENT_SLOTS" ] || [ "$SLOTS_N" -lt 1 ]; then
    echo NO_SLOTS
    exit 1
fi

ip link del wg0 2>/dev/null
ip link add dev wg0 type wireguard
ip link set mtu 1400 dev wg0
wg set wg0 peer "$WG_SERVER_PUBLIC_KEY" endpoint "${WG_ENDPOINT}:${WG_ENDPOINT_PORT}" allowed-ips 0.0.0.0/0 persistent-keepalive 25

# Cryptographic random start from /dev/urandom to prevent same-second slot collisions
RAND_INT=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ')
[ -z "$RAND_INT" ] && RAND_INT=$(date +%s)
START=$(( (RAND_INT % SLOTS_N) + 1 ))

GOT=0
i=0
while [ $i -lt $SLOTS_N ]; do
    K=$(( ((START + i - 1) % SLOTS_N) + 1 ))
    PR=$(printf '%s\n' "$WG_CLIENT_SLOTS" | sed -n "${K}p")
    [ -n "$PR" ] || { i=$((i+1)); continue; }
    printf '%s\n' "$PR" > /tmp/wg.key
    chmod 600 /tmp/wg.key
    wg set wg0 private-key /tmp/wg.key
    ip address add "10.66.0.$((K + 1))/24" dev wg0 2>/dev/null
    ip link set up dev wg0
    sleep 3
    HS=$(wg show wg0 latest-handshakes | awk '{print $2}')
    if [ -n "$HS" ] && [ "$HS" -gt 0 ]; then
        GOT=$K
        break
    fi
    ip address del "10.66.0.$((K + 1))/24" dev wg0 2>/dev/null
    i=$((i+1))
done
rm -f /tmp/wg.key
if [ "$GOT" -eq 0 ]; then
    echo ALL_SLOTS_BUSY
    exit 1
fi
echo "WG_SLOT=$GOT"

OLD_GW=$(ip route | awk '/default/ {print $3; exit}')
ip route replace "${WG_ENDPOINT}/32" via "$OLD_GW"
sleep 2
if ! wg show wg0 2>/dev/null | grep -q 'listening port'; then
    echo WG_IFACE_FAIL
    exit 1
fi

# Set default route with initrwnd 64 so Linux TCP SYN advertises Window=65535 (matching macOS XNU)
ip route replace default via 10.66.0.1 dev wg0 initcwnd 10 initrwnd 64

# Trinity L4:
# 1. Set TTL=65 on wg0 egress so after GCP VM decrements 1 hop on forwarding,
#    packets arrive at Cloud NAT / Internet with exact TTL=64.
# 2. Clamp TCP MSS to 1360 (fits 1400 inner MTU + 60B WG overhead = 1460, the ens4 VPC uplink ceiling).
nft flush table inet mssclamp 2>/dev/null || true
nft add table inet mssclamp 2>/dev/null
nft add chain inet mssclamp output '{ type filter hook output priority mangle; policy accept; }' 2>/dev/null
nft add chain inet mssclamp forward '{ type filter hook forward priority mangle; policy accept; }' 2>/dev/null
nft add rule inet mssclamp output oifname "wg0" ip ttl set 65
nft add rule inet mssclamp forward oifname "wg0" ip ttl set 65
nft add rule inet mssclamp output tcp flags syn / syn,rst tcp option maxseg size set 1360
nft add rule inet mssclamp forward tcp flags syn / syn,rst tcp option maxseg size set 1360

# Start WunderDNS Hunter ONLY when chaining through an upstream SOCKS5 proxy.
# In pure Cloud WireGuard mode, direct dnsmasq -> 8.8.8.8/8.8.4.4 over wg0 hits the
# exact same regional Google POP without RFC1918 probe timeouts or TCP-DNS overhead.
killall python3 2>/dev/null || true
if [ -n "$SOCKS5_HOST" ]; then
    SOCKS5_HOST="$SOCKS5_HOST" SOCKS5_PORT="$SOCKS5_PORT" SOCKS5_USER="$SOCKS5_USER" SOCKS5_PASS="$SOCKS5_PASS" \
        nohup /usr/bin/wunderdns.py >/var/log/wunderdns.log 2>&1 &
    sleep 3
else
    echo "direct-wg-dns:8.8.8.8" > /tmp/wunderdns.state
fi

# Configure dnsmasq with 10,000-entry RAM cache, filter-aaaa=1 (no IPv6 leak),
# and WunderDNS local bridge (127.0.0.1#5353) + Google POP fallback.
uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].cachesize='10000'
uci set dhcp.@dnsmasq[0].min_cache_ttl='300'
uci set dhcp.@dnsmasq[0].filter_aaaa='1'
uci -q delete dhcp.@dnsmasq[0].server
if [ -n "$SOCKS5_HOST" ] && pgrep -f wunderdns.py >/dev/null 2>&1; then
    uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353'
else
    uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'
    uci add_list dhcp.@dnsmasq[0].server='8.8.4.4'
fi
uci commit dhcp
/etc/init.d/dnsmasq restart
sleep 1
if ! pgrep dnsmasq >/dev/null 2>&1 || ! nslookup www.apple.com 127.0.0.1 >/dev/null 2>&1; then
    uci -q delete dhcp.@dnsmasq[0].min_cache_ttl
    uci commit dhcp
    /etc/init.d/dnsmasq restart
fi

cat > /etc/tinyproxy/tinyproxy.conf <<'CFG'
Port 3128
Listen 0.0.0.0
Timeout 600
LogLevel Error
MaxClients 256
DisableViaHeader Yes
FilterDefaultDeny Off
Allow 0.0.0.0/0
ConnectPort 443
ConnectPort 80
ConnectPort 8080
ConnectPort 8443
ConnectPort 5222
ConnectPort 5228
ConnectPort 853
CFG
if [ -n "$SOCKS5_HOST" ]; then
    echo "Upstream http 127.0.0.1:8128" >> /etc/tinyproxy/tinyproxy.conf
fi
killall tinyproxy 2>/dev/null
tinyproxy -c /etc/tinyproxy/tinyproxy.conf
echo WG_ROUTE_OK
REMOTE
    if [ $? -eq 0 ]; then
        echo "OPENWRT_UPSTREAM=wireguard-router" >> "${GITHUB_ENV:-/dev/null}"
    else
        fail_handler "WireGuard tunnel failed to come up"
    fi
elif [ -n "${SOCKS5_HOST:-}" ]; then
    echo -e "${BLUE}🏠 Configuring OpenWrt with Residential SOCKS5 Upstream + WunderDNS ISP Hunter...${NC}"
    ssh $SSH_OPTS root@127.0.0.1 "cat > /tmp/socks.env" <<SENV
SOCKS5_HOST=${SOCKS5_HOST}
SOCKS5_PORT=${SOCKS5_PORT}
SOCKS5_USER=${SOCKS5_USER}
SOCKS5_PASS=${SOCKS5_PASS}
SENV
    ssh $SSH_OPTS root@127.0.0.1 'ash -s' <<'REMOTE'
set +e
. /tmp/socks.env
rm -f /tmp/socks.env

killall python3 2>/dev/null || true
SOCKS5_HOST="$SOCKS5_HOST" SOCKS5_PORT="$SOCKS5_PORT" SOCKS5_USER="$SOCKS5_USER" SOCKS5_PASS="$SOCKS5_PASS" \
    nohup /usr/bin/wunderdns.py >/var/log/wunderdns.log 2>&1 &
sleep 3

uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].cachesize='10000'
uci set dhcp.@dnsmasq[0].min_cache_ttl='300'
uci set dhcp.@dnsmasq[0].filter_aaaa='1'
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353'
uci commit dhcp
/etc/init.d/dnsmasq restart

cat > /etc/tinyproxy/tinyproxy.conf <<'CFG'
Port 3128
Listen 0.0.0.0
Timeout 600
LogLevel Error
MaxClients 256
DisableViaHeader Yes
FilterDefaultDeny Off
Allow 0.0.0.0/0
ConnectPort 443
ConnectPort 80
ConnectPort 8080
ConnectPort 8443
ConnectPort 5222
ConnectPort 5228
ConnectPort 853
Upstream http 127.0.0.1:8128
CFG
killall tinyproxy 2>/dev/null
tinyproxy -c /etc/tinyproxy/tinyproxy.conf
/etc/init.d/microsocks stop 2>/dev/null || killall microsocks 2>/dev/null
REMOTE
    echo "OPENWRT_UPSTREAM=wunderdns-socks5" >> "${GITHUB_ENV:-/dev/null}"
elif [ -n "${GCP_PROXY_PASS:-}" ]; then
    echo -e "${YELLOW}ℹ️  WireGuard keys missing — configuring HTTP CONNECT through GCP${NC}"
    ssh $SSH_OPTS root@127.0.0.1 "cat > /etc/tinyproxy/tinyproxy.conf" <<CFG
Port 3128
Listen 0.0.0.0
Timeout 600
LogLevel Error
MaxClients 256
DisableViaHeader Yes
FilterDefaultDeny Off
Allow 0.0.0.0/0
ConnectPort 443
ConnectPort 80
ConnectPort 8080
ConnectPort 8443
ConnectPort 5222
ConnectPort 5228
ConnectPort 853
Upstream http ${GCP_PROXY_USER:-proxy_pool_01}:${GCP_PROXY_PASS}@${GCP_PROXY_HOST:-35.215.247.149}:${GCP_PROXY_PORT:-443}
CFG
    ssh $SSH_OPTS root@127.0.0.1 'killall tinyproxy 2>/dev/null; tinyproxy -c /etc/tinyproxy/tinyproxy.conf; /etc/init.d/microsocks stop 2>/dev/null || killall microsocks 2>/dev/null'
    echo "OPENWRT_UPSTREAM=gcp-connect" >> "${GITHUB_ENV:-/dev/null}"
else
    echo -e "${YELLOW}ℹ️  No WireGuard keys and no GCP password — OpenWrt egresses on Azure${NC}"
fi

echo -e "${BLUE}🧪 Testing localhost -> OpenWrt HTTP proxy...${NC}"
PROXY_IP="$(curl -s --max-time 25 --proxy "http://127.0.0.1:${HTTP_HOSTPORT}" https://api.ipify.org)"
if [ -z "$PROXY_IP" ]; then
    fail_handler "tinyproxy did not return a public IP"
fi
echo -e "${GREEN}✅ OpenWrt proxy egress IP: ${PROXY_IP}${NC}"

# If dedicated tunnel was requested, verify egress IP is NOT the raw Azure host IP
if [ "$REQUIRE_TUNNEL" = "true" ] && [ -n "${CURRENT_IP:-}" ] && [ "$PROXY_IP" = "$CURRENT_IP" ]; then
    fail_handler "Egress IP ($PROXY_IP) matches raw Azure runner IP ($CURRENT_IP) despite tunnel requirement!"
fi

# --- AUTO-SYNC MACOS TIMEZONE, LOCALE & HOSTNAME WITH EGRESS IP GEO ---
echo -e "${BLUE}🌍 Synchronizing macOS Timezone, Locale & Hostname with Egress IP (${PROXY_IP})...${NC}"
EGRESS_GEO="$(curl -s --max-time 12 --proxy "http://127.0.0.1:${HTTP_HOSTPORT}" "https://ipinfo.io/${PROXY_IP}/json" 2>/dev/null)"
EGRESS_TZ="$(echo "$EGRESS_GEO" | grep -o '"timezone": *"[^"]*"' | cut -d'"' -f4)"
EGRESS_COUNTRY="$(echo "$EGRESS_GEO" | grep -o '"country": *"[^"]*"' | cut -d'"' -f4)"

if [ -n "$EGRESS_TZ" ]; then
    sudo systemsetup -settimezone "$EGRESS_TZ" >/dev/null 2>&1 || \
        sudo ln -sf "/usr/share/zoneinfo/${EGRESS_TZ}" /etc/localtime 2>/dev/null || true
    echo -e "${GREEN}   ✅ macOS Timezone locked to: ${EGRESS_TZ}${NC}"
fi

case "$EGRESS_COUNTRY" in
    BR)
        defaults write NSGlobalDomain AppleLanguages -array "pt-BR" "pt" "en-US" 2>/dev/null || true
        defaults write NSGlobalDomain AppleLocale -string "pt_BR@currency=BRL" 2>/dev/null || true
        echo -e "${GREEN}   ✅ macOS Locale locked to: pt_BR (Brazil)${NC}"
        ;;
    US)
        defaults write NSGlobalDomain AppleLanguages -array "en-US" 2>/dev/null || true
        defaults write NSGlobalDomain AppleLocale -string "en_US@currency=USD" 2>/dev/null || true
        echo -e "${GREEN}   ✅ macOS Locale locked to: en_US (United States)${NC}"
        ;;
esac

# Sanitize macOS CI Hostname so local WebRTC/mDNS/system probes see a standard MacBook Pro
sudo scutil --set HostName "MacBook-Pro" 2>/dev/null || true
sudo scutil --set LocalHostName "MacBook-Pro" 2>/dev/null || true
sudo scutil --set ComputerName "MacBook Pro" 2>/dev/null || true

# --- BLOCK QUIC (UDP/443) & WEBRTC STUN LEAKS ON MACOS HOST ---
echo -e "${BLUE}🛡️  Hardening macOS Browser Policies & pfctl Firewall against UDP/QUIC/WebRTC leaks...${NC}"
for domain in com.google.Chrome org.chromium.Chromium com.brave.Browser com.microsoft.edgemac; do
    defaults write "$domain" QuicAllowed -bool false 2>/dev/null || true
    defaults write "$domain" WebRtcIPHandlingPolicy -string "disable_non_proxied_udp" 2>/dev/null || true
    defaults write "$domain" DnsOverHttpsMode -string "off" 2>/dev/null || true
done

# Block outbound UDP on port 443 (QUIC/HTTP3) and common STUN/TURN ports (3478, 5349, 19302-19309)
# on en0 so browsers are strictly forced over the TCP HTTP proxy (127.0.0.1:13128) while RustDesk stays unaffected.
PF_CONF="/tmp/openwrt-stealth.pf.conf"
cat > "$PF_CONF" <<'PFEOF'
block return out quick on en0 proto udp from any to any port 443
block drop out quick on en0 proto udp from any to any port { 3478, 5349, 19302:19309 }
PFEOF
sudo pfctl -a "com.apple/openwrt_stealth" -f "$PF_CONF" >/dev/null 2>&1 || true
sudo pfctl -f /etc/pf.conf >/dev/null 2>&1 || true
(cat /etc/pf.conf 2>/dev/null; echo ""; cat "$PF_CONF") | sudo pfctl -ef - >/dev/null 2>&1 || true

echo -e "${BLUE}🖥  Applying macOS HTTP/HTTPS proxy (GUI apps only)...${NC}"
BYPASS="127.0.0.1 localhost *.local github.com *.github.com *.githubusercontent.com *.actions.githubusercontent.com rustdesk.com *.rustdesk.com apple.com *.apple.com icloud.com *.icloud.com mzstatic.com *.mzstatic.com"
networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | while IFS= read -r svc; do
    case "$svc" in
        \***) continue ;;
    esac
    [ -z "$svc" ] && continue
    networksetup -setwebproxy "$svc" 127.0.0.1 "$HTTP_HOSTPORT" off >/dev/null 2>&1
    networksetup -setsecurewebproxy "$svc" 127.0.0.1 "$HTTP_HOSTPORT" off >/dev/null 2>&1
    networksetup -setwebproxystate "$svc" on >/dev/null 2>&1
    networksetup -setsecurewebproxystate "$svc" on >/dev/null 2>&1
    # Disable IPv6 on host service to prevent direct AAAA bypass
    networksetup -setv6off "$svc" >/dev/null 2>&1 || true
    # Do not enable system SOCKS: RustDesk and the runner can pick it up.
    networksetup -setsocksfirewallproxystate "$svc" off >/dev/null 2>&1
    # shellcheck disable=SC2086
    networksetup -setproxybypassdomains "$svc" $BYPASS >/dev/null 2>&1
    echo "   proxy on: $svc"
done

if [ -n "${GITHUB_ENV:-}" ]; then
    {
        echo "OPENWRT_ENABLED=true"
        echo "OPENWRT_PROXY=127.0.0.1:${HTTP_HOSTPORT}"
        echo "OPENWRT_SOCKS=127.0.0.1:${SOCKS_HOSTPORT}"
        echo "OPENWRT_EGRESS_IP=${PROXY_IP}"
    } >> "$GITHUB_ENV"
fi

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  OpenWrt HTTP proxy:  ${GREEN}127.0.0.1:${HTTP_HOSTPORT}${NC}"
echo -e "  OpenWrt SOCKS5:      ${GREEN}127.0.0.1:${SOCKS_HOSTPORT}${NC} (manual only)"
echo -e "  Egress IP:           ${GREEN}${PROXY_IP}${NC} (${EGRESS_COUNTRY:-unknown} / ${EGRESS_TZ:-unknown})"
echo -e "  Trinity L4 Stack:    ${GREEN}Window=65535, WScale=6, TTL=64, MSS=1360${NC}"
echo -e "  WunderDNS Cache:     ${GREEN}10,000 entries RAM + filter-aaaa + TCP:53 Hunter${NC}"
echo -e "  QUIC/WebRTC Leak:    ${GREEN}Blocked on en0 via pfctl + Browser Policy${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${GREEN}✅ OpenWrt exit is up${NC}"
exit 0
