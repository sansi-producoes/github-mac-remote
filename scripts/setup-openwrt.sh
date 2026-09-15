#!/bin/bash
# setup-openwrt.sh
# Boot OpenWrt inside the macOS GitHub runner (QEMU TCG/HVF) and point
# GUI apps at a localhost HTTP proxy that egresses through the VM.
#
# Why a localhost proxy instead of replacing the default route:
#   stealing the Mac default gateway kills GitHub Actions, artifact
#   upload, and RustDesk. HTTP/HTTPS system proxy covers Safari/Chrome
#   while the runner and RustDesk stay on the native Azure path.
#
# Env:
#   OPENWRT_VERSION   (default 24.10.0)
#   BUILD_DIR         (default build)
#   OPENWRT_RAM_MB    (default 384)
#   OPENWRT_CPUS      (default 2)

set +e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.0}"
BUILD="${BUILD_DIR:-build}"
OPENWRT_RAM_MB="${OPENWRT_RAM_MB:-384}"
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

fail_soft() {
    echo -e "${YELLOW}⚠️  OpenWrt setup did not finish: $1${NC}"
    echo "OPENWRT_ENABLED=false" >> "${GITHUB_ENV:-/dev/null}"
    echo "The RustDesk session will continue without the OpenWrt exit."
    exit 0
}

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              🧭 OPENWRT EXIT (inside this Mac)                   ║${NC}"
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
        fail_soft "unsupported arch $HOST_ARCH"
        ;;
esac

echo -e "${BLUE}📦 Installing QEMU + e2fsprogs (Homebrew)...${NC}"
if ! command -v brew >/dev/null 2>&1; then
    fail_soft "Homebrew is not available on this runner"
fi
brew list qemu >/dev/null 2>&1 || brew install qemu
brew list e2fsprogs >/dev/null 2>&1 || brew install e2fsprogs

QEMU_BIN="$(command -v "$QEMU_BIN_NAME")"
DEBUGFS="$(brew --prefix e2fsprogs)/sbin/debugfs"
if [ ! -x "$QEMU_BIN" ]; then
    fail_soft "$QEMU_BIN_NAME not found after brew install"
fi
if [ ! -x "$DEBUGFS" ]; then
    fail_soft "debugfs not found after brew install e2fsprogs"
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
    fail_soft "UEFI firmware $FW_NAME not found"
fi

IMG_GZ="$BUILD/openwrt-${OPENWRT_VERSION}-${OPENWRT_PROFILE}.img.gz"
IMG_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${OPENWRT_TARGET_PATH}/openwrt-${OPENWRT_VERSION}-${OPENWRT_PROFILE}-ext4-combined-efi.img.gz"

echo -e "${BLUE}📥 Downloading OpenWrt ${OPENWRT_VERSION} (${OPENWRT_PROFILE})...${NC}"
if [ ! -s "$IMG_GZ" ]; then
    curl -fL --retry 3 --retry-delay 2 -o "$IMG_GZ" "$IMG_URL" || fail_soft "failed to download OpenWrt image"
fi

echo -e "${BLUE}📂 Decompressing image...${NC}"
gzip -dc "$IMG_GZ" > "$IMG" || true
[ -s "$IMG" ] || fail_soft "decompressed image is empty"

echo -e "${BLUE}🔑 Generating OpenWrt root SSH key...${NC}"
rm -f "$SSH_KEY" "$SSH_KEY.pub"
ssh-keygen -t ed25519 -N '' -f "$SSH_KEY" -C "gha-mac-openwrt" -q
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
set system.@system[0].hostname='gha-mac-openwrt'
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
)" || fail_soft "could not parse GPT on OpenWrt image"

P2_START="${GPT_INFO%% *}"
P2_COUNT="${GPT_INFO##* }"
ROOTFS="$BUILD/rootfs.img"
dd if="$IMG" of="$ROOTFS" bs=512 skip="$P2_START" count="$P2_COUNT" status=none || fail_soft "failed to extract rootfs partition"
"$DEBUGFS" -R "stats" "$ROOTFS" >/dev/null 2>&1 || fail_soft "extracted rootfs is not a readable ext4 image"

# macOS getopt stops at the first non-option. -R/-w MUST come before the image.
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
        fail_soft "debugfs write failed for $dest"
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
    fail_soft "network config was not written into the OpenWrt rootfs"
fi
VERIFY_KEY="$("$DEBUGFS" -R "stat /etc/dropbear/authorized_keys" "$ROOTFS" 2>/dev/null)"
if ! echo "$VERIFY_KEY" | grep -qi "type: regular"; then
    echo "$VERIFY_KEY"
    fail_soft "authorized_keys was not written into the OpenWrt rootfs"
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

dd if="$ROOTFS" of="$IMG" bs=512 seek="$P2_START" conv=notrunc status=none || fail_soft "failed to write rootfs back"

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
        start_qemu "-accel tcg -cpu max" || fail_soft "QEMU exited immediately (see $QEMU_LOG)"
    fi
else
    echo -e "${YELLOW}HVF unavailable — using TCG (slower first boot)${NC}"
    start_qemu "-accel tcg -cpu max" || fail_soft "QEMU exited immediately (see $QEMU_LOG)"
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
    fail_soft "OpenWrt did not become reachable on 127.0.0.1:${SSH_HOSTPORT}"
fi

echo -e "${BLUE}📦 Installing tinyproxy + microsocks inside OpenWrt...${NC}"
ssh $SSH_OPTS root@127.0.0.1 'ash -s' <<'REMOTE'
set +e
opkg update
opkg install tinyproxy
opkg install microsocks

# Reachable only via QEMU hostfwd from 127.0.0.1 on the Mac.
if uci -q get tinyproxy.@tinyproxy[0] >/dev/null 2>&1; then
    uci set tinyproxy.@tinyproxy[0].enabled='1'
    uci set tinyproxy.@tinyproxy[0].Port='3128'
    uci set tinyproxy.@tinyproxy[0].Listen='0.0.0.0'
    uci -q delete tinyproxy.@tinyproxy[0].Allow
    uci add_list tinyproxy.@tinyproxy[0].Allow='0.0.0.0/0'
    uci commit tinyproxy
fi

mkdir -p /etc/tinyproxy
cat > /etc/tinyproxy/tinyproxy.conf <<'CFG'
Port 3128
Listen 0.0.0.0
Timeout 600
LogLevel Info
MaxClients 100
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
WG_OPENWRT_PRIVATE_KEY="${WG_OPENWRT_PRIVATE_KEY:-}"
WG_SERVER_PUBLIC_KEY="${WG_SERVER_PUBLIC_KEY:-}"

if [ -n "$WG_OPENWRT_PRIVATE_KEY" ] && [ -n "$WG_SERVER_PUBLIC_KEY" ]; then
    echo -e "${BLUE}🛣  Making OpenWrt the router: WireGuard to GCP, SNAT only (no HTTP CONNECT)...${NC}"
    ssh $SSH_OPTS root@127.0.0.1 "cat > /tmp/wg.env" <<WGENV
WG_ENDPOINT=${WG_ENDPOINT}
WG_ENDPOINT_PORT=${WG_ENDPOINT_PORT}
WG_OPENWRT_PRIVATE_KEY=${WG_OPENWRT_PRIVATE_KEY}
WG_SERVER_PUBLIC_KEY=${WG_SERVER_PUBLIC_KEY}
WGENV
    ssh $SSH_OPTS root@127.0.0.1 'ash -s' <<'REMOTE'
set +e
. /tmp/wg.env
rm -f /tmp/wg.env
opkg update
opkg install wireguard-tools kmod-wireguard

uci -q delete network.wg0
uci set network.wg0=interface
uci set network.wg0.proto='wireguard'
uci set network.wg0.private_key="$WG_OPENWRT_PRIVATE_KEY"
uci add_list network.wg0.addresses='10.66.0.2/24'
uci set network.wg0.mtu='1280'

while uci -q delete network.@wireguard_wg0[0]; do :; done
uci add network wireguard_wg0
uci set network.@wireguard_wg0[-1].public_key="$WG_SERVER_PUBLIC_KEY"
uci set network.@wireguard_wg0[-1].endpoint_host="$WG_ENDPOINT"
uci set network.@wireguard_wg0[-1].endpoint_port="$WG_ENDPOINT_PORT"
uci set network.@wireguard_wg0[-1].persistent_keepalive='25'
uci add_list network.@wireguard_wg0[-1].allowed_ips='0.0.0.0/0'
uci set network.@wireguard_wg0[-1].route_allowed_ips='0'
uci commit network
ifup wg0
sleep 3

OLD_GW=$(ip route | awk '/default/ {print $3; exit}')
ip route replace "${WG_ENDPOINT}/32" via "$OLD_GW"
ip link set up dev wg0 2>/dev/null
sleep 2
if ! wg show wg0 2>/dev/null | grep -q 'listening port'; then
    echo WG_IFACE_FAIL
    exit 1
fi
ip route replace default via 10.66.0.1 dev wg0
nft add table inet mssclamp 2>/dev/null
nft add chain inet mssclamp output '{ type filter hook output priority mangle; policy accept; }' 2>/dev/null
nft add chain inet mssclamp forward '{ type filter hook forward priority mangle; policy accept; }' 2>/dev/null
nft add rule inet mssclamp output tcp flags syn / syn,rst tcp option maxseg size set 1240
nft add rule inet mssclamp forward tcp flags syn / syn,rst tcp option maxseg size set 1240
echo WG_ROUTE_OK

cat > /etc/tinyproxy/tinyproxy.conf <<'CFG'
Port 3128
Listen 0.0.0.0
Timeout 600
LogLevel Info
MaxClients 100
Allow 0.0.0.0/0
ConnectPort 443
ConnectPort 80
ConnectPort 8080
ConnectPort 8443
ConnectPort 5222
ConnectPort 5228
ConnectPort 853
CFG
killall tinyproxy 2>/dev/null
tinyproxy -c /etc/tinyproxy/tinyproxy.conf
REMOTE
    if [ $? -eq 0 ]; then
        echo "OPENWRT_UPSTREAM=wireguard-router" >> "${GITHUB_ENV:-/dev/null}"
    else
        echo -e "${YELLOW}WireGuard did not come up — OpenWrt stays on Azure${NC}"
    fi
elif [ -n "${GCP_PROXY_PASS:-}" ]; then
    echo -e "${YELLOW}ℹ️  WireGuard keys missing — falling back to HTTP CONNECT through GCP${NC}"
    ssh $SSH_OPTS root@127.0.0.1 "cat > /etc/tinyproxy/tinyproxy.conf" <<CFG
Port 3128
Listen 0.0.0.0
Timeout 600
LogLevel Info
MaxClients 100
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
    ssh $SSH_OPTS root@127.0.0.1 'killall tinyproxy 2>/dev/null; tinyproxy -c /etc/tinyproxy/tinyproxy.conf'
    echo "OPENWRT_UPSTREAM=gcp-connect" >> "${GITHUB_ENV:-/dev/null}"
else
    echo -e "${YELLOW}ℹ️  No WireGuard keys and no GCP password — OpenWrt egresses on Azure${NC}"
fi

echo -e "${BLUE}🧪 Testing localhost -> OpenWrt HTTP proxy...${NC}"
PROXY_IP="$(curl -s --max-time 25 --proxy "http://127.0.0.1:${HTTP_HOSTPORT}" https://api.ipify.org)"
if [ -z "$PROXY_IP" ]; then
    fail_soft "tinyproxy did not return a public IP"
fi
echo -e "${GREEN}✅ OpenWrt proxy egress IP: ${PROXY_IP}${NC}"

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
echo -e "  Egress IP:           ${GREEN}${PROXY_IP}${NC}"
echo -e "  Safari / Chrome:     use the system HTTP proxy automatically"
echo -e "  GitHub Actions:      stays direct (no HTTP_PROXY in GITHUB_ENV)"
echo -e "  RustDesk:            stays direct (bypass + no SOCKS)"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${GREEN}✅ OpenWrt exit is up${NC}"
exit 0
