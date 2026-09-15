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

inject_file() {
    local src
    src="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
    local dest="$2"
    local mode="$3"
    "$DEBUGFS" -w "$ROOTFS" -R "unlink $dest" >/dev/null 2>&1
    "$DEBUGFS" -w "$ROOTFS" -R "write $src $dest" >/dev/null 2>&1
    "$DEBUGFS" -w "$ROOTFS" -R "sif $dest mode $mode" >/dev/null 2>&1
}

"$DEBUGFS" -w "$ROOTFS" -R "mkdir /etc/uci-defaults" >/dev/null 2>&1
"$DEBUGFS" -w "$ROOTFS" -R "mkdir /etc/dropbear" >/dev/null 2>&1
"$DEBUGFS" -w "$ROOTFS" -R "mkdir /etc/modprobe.d" >/dev/null 2>&1
inject_file "$BOOTSTRAP" "/etc/uci-defaults/99-mac-bootstrap" 0100755
inject_file "$SSH_KEY.pub" "/etc/dropbear/authorized_keys" 0100600
inject_file "$BLACKLIST" "/etc/modprobe.d/00-gha-virt-blacklist.conf" 0100644

if [ "$STRIP_ARM_KMODS" = "1" ]; then
    echo -e "${BLUE}🧹 Stripping ARM server NIC autoload (avoids TCG boot stalls)...${NC}"
    MODULE_LIST="$("$DEBUGFS" -R "ls -p /etc/modules.d" "$ROOTFS" 2>/dev/null)"
    echo "$MODULE_LIST" | tr '/' '\n' | while read -r name; do
        [ -z "$name" ] && continue
        case "$name" in
            *macsec*|*vmxnet3*|*thunder*|*rvu*|*nicpf*|*nicvf*|*e1000*|*ppp*|*octeon*|*marvell*|*cavium*|*ena*|*ixgbe*|*i40e*|*mlx*|*bnxt*|*qede*|*tg3*|*sfc*|*bcm*|*mvneta*|*mvpp2*|*stmmac*|*dwmac*|*atlantic*|*aquantia*|*realtek*|*smsc*|*phylib*|*enetc*|*dpaa*)
                "$DEBUGFS" -w "$ROOTFS" -R "unlink /etc/modules.d/$name" >/dev/null 2>&1
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
    if ssh $SSH_OPTS root@127.0.0.1 "test -f /etc/.gha-bootstrap-done && echo READY" 2>/dev/null | grep -q READY; then
        READY=1
        echo -e "${GREEN}✅ OpenWrt is reachable over SSH${NC}"
        break
    fi
    printf "\r   waiting... %s/96" "$i"
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
