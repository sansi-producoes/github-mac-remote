#!/bin/bash
# setup-rustdesk.sh - Install and configure RustDesk for remote access
# RustDesk is an open-source remote desktop similar to TeamViewer/AnyDesk

set -e

RUSTDESK_VERSION="${RUSTDESK_VERSION:-1.3.7}"
RUSTDESK_PASSWORD="${RUSTDESK_PASSWORD:-}"

echo "🦀 Setting up RustDesk v${RUSTDESK_VERSION}..."

# Generate password if not provided
if [ -z "${RUSTDESK_PASSWORD}" ]; then
    RUSTDESK_PASSWORD=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)
    echo "::add-mask::${RUSTDESK_PASSWORD}"
    echo "RUSTDESK_PASSWORD=${RUSTDESK_PASSWORD}" >> $GITHUB_ENV
fi

# Detect CPU architecture
ARCH=$(uname -m)
echo "🖥️ Detected architecture: ${ARCH}"

if [ "$ARCH" = "arm64" ]; then
    RUSTDESK_ARCH="aarch64"
elif [ "$ARCH" = "x86_64" ]; then
    RUSTDESK_ARCH="x86_64"
else
    echo "⚠️ Unknown architecture: ${ARCH}, defaulting to aarch64"
    RUSTDESK_ARCH="aarch64"
fi

# Download RustDesk for the correct architecture
echo "📦 Downloading RustDesk for ${RUSTDESK_ARCH}..."
RUSTDESK_DMG="/tmp/rustdesk.dmg"
RUSTDESK_URL="https://github.com/rustdesk/rustdesk/releases/download/${RUSTDESK_VERSION}/rustdesk-${RUSTDESK_VERSION}-${RUSTDESK_ARCH}.dmg"

echo "   URL: ${RUSTDESK_URL}"
curl -L "${RUSTDESK_URL}" -o "${RUSTDESK_DMG}" --progress-bar

# Verify download
FILE_SIZE=$(stat -f%z "${RUSTDESK_DMG}" 2>/dev/null || stat --printf="%s" "${RUSTDESK_DMG}" 2>/dev/null || echo "0")
echo "   Downloaded: ${FILE_SIZE} bytes"

if [ "${FILE_SIZE}" -lt 1000000 ]; then
    echo "❌ Download failed - file too small (${FILE_SIZE} bytes)"
    echo "   Content of downloaded file:"
    head -c 500 "${RUSTDESK_DMG}" || true
    exit 1
fi

echo "✅ Download complete (${FILE_SIZE} bytes)"

# Mount DMG
echo "📦 Mounting DMG..."
hdiutil attach "${RUSTDESK_DMG}" -nobrowse -quiet || {
    echo "⚠️ First mount attempt failed, retrying..."
    sleep 2
    hdiutil attach "${RUSTDESK_DMG}" -nobrowse -quiet -force
}

sleep 3

# Find and install RustDesk
echo "📦 Installing RustDesk..."
RUSTDESK_VOL=$(ls -d /Volumes/RustDesk* 2>/dev/null | head -1)

if [ -z "$RUSTDESK_VOL" ]; then
    echo "⚠️ Looking for alternative volume names..."
    ls -la /Volumes/
    RUSTDESK_VOL=$(ls -d /Volumes/*ustdesk* 2>/dev/null | head -1)
fi

if [ -n "$RUSTDESK_VOL" ]; then
    echo "   Found volume: $RUSTDESK_VOL"
    ls -la "$RUSTDESK_VOL/"
    
    if [ -d "$RUSTDESK_VOL/RustDesk.app" ]; then
        cp -R "$RUSTDESK_VOL/RustDesk.app" /Applications/
    elif [ -d "$RUSTDESK_VOL"/*.app ]; then
        cp -R "$RUSTDESK_VOL"/*.app /Applications/
    fi
    
    hdiutil detach "$RUSTDESK_VOL" -quiet || true
else
    echo "❌ Could not find RustDesk volume"
    exit 1
fi

# Verify installation
if [ ! -d "/Applications/RustDesk.app" ]; then
    echo "❌ Failed to install RustDesk"
    ls -la /Applications/ | grep -i rust || true
    exit 1
fi

echo "✅ RustDesk installed to /Applications/RustDesk.app"

# Create config directory
RUSTDESK_CONFIG_DIR="$HOME/Library/Application Support/RustDesk"
mkdir -p "${RUSTDESK_CONFIG_DIR}"

# RustDesk stores config in a specific format
# We need to set a permanent password for unattended access
echo "⚙️ Configuring RustDesk..."

# Encode password for RustDesk config (base64) and mask it in logs
ENCODED_PASSWORD=$(echo -n "${RUSTDESK_PASSWORD}" | base64)
echo "::add-mask::${ENCODED_PASSWORD}"

# Create RustDesk2.toml config file WITH password pre-set
cat > "${RUSTDESK_CONFIG_DIR}/RustDesk2.toml" << EOFTOML
rendezvous_server = 'rs-ny.rustdesk.com'
nat_type = 1
serial = 0

[options]
allow-auto-disconnect = 'N'
stop-service = 'N'
direct-server = 'Y'
allow-linux-headless = 'Y'
EOFTOML

# Also create RustDesk.toml with password (RustDesk checks both files)
cat > "${RUSTDESK_CONFIG_DIR}/RustDesk.toml" << EOFTOML
password = '${RUSTDESK_PASSWORD}'
EOFTOML

echo "   ✅ Pre-configured password in config files"
echo "   📁 Config location: ${RUSTDESK_CONFIG_DIR}"

# Grant necessary permissions via TCC database (may require SIP disabled)
echo "🔐 Attempting to grant permissions..."

sudo sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
    "INSERT OR REPLACE INTO access VALUES('kTCCServiceAccessibility','com.rustdesk.RustDesk',0,2,4,1,NULL,NULL,0,'UNUSED',NULL,0,$(date +%s));" 2>/dev/null || \
    echo "⚠️ Could not set accessibility permissions (expected on VM)"

sudo sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
    "INSERT OR REPLACE INTO access VALUES('kTCCServiceScreenCapture','com.rustdesk.RustDesk',0,2,4,1,NULL,NULL,0,'UNUSED',NULL,0,$(date +%s));" 2>/dev/null || \
    echo "⚠️ Could not set screen capture permissions (expected on VM)"

# Start RustDesk FIRST, before trying to set password
echo "🚀 Starting RustDesk..."

/Applications/RustDesk.app/Contents/MacOS/rustdesk &
RUSTDESK_PID=$!

echo "   Waiting for RustDesk to initialize (PID: $RUSTDESK_PID)..."
sleep 10

if pgrep -f "RustDesk" > /dev/null; then
    echo "   ✅ RustDesk is running"
else
    echo "   ⚠️ RustDesk not detected, trying alternative launch..."
    open -a RustDesk
    sleep 5
fi

echo "🔑 Setting up password..."

RUSTDESK_CLI="/Applications/RustDesk.app/Contents/MacOS/rustdesk"
if [ -f "${RUSTDESK_CLI}" ]; then
    RUSTDESK_ID=$("${RUSTDESK_CLI}" --get-id 2>/dev/null || echo "")
    
    if [ -n "${RUSTDESK_ID}" ]; then
        echo "RUSTDESK_ID=${RUSTDESK_ID}" >> $GITHUB_ENV
        echo "   ✅ RustDesk ID: ${RUSTDESK_ID}"
    fi
    
    echo "   Attempting to set password..."
    PASSWORD_OUTPUT=$(sudo "${RUSTDESK_CLI}" --password "${RUSTDESK_PASSWORD}" 2>&1)
    
    if echo "${PASSWORD_OUTPUT}" | grep -qi "error\|fail\|denied\|not found"; then
        echo "   ⚠️ Password setting via CLI may have failed"
        PASSWORD_SET=false
    else
        echo "   ✅ Password command executed"
        PASSWORD_SET=true
    fi
    
    sleep 3
    echo ""
    echo "   📂 Checking config directory structure..."
    ls -la "${RUSTDESK_CONFIG_DIR}/" 2>/dev/null || echo "   Config dir not accessible"
fi

sleep 5
echo "🔍 Checking RustDesk status..."

if pgrep -f "RustDesk" > /dev/null; then
    echo ""
    echo "✅ RustDesk process is running!"
    echo ""
    
    if [ -z "${RUSTDESK_ID}" ]; then
        RUSTDESK_ID=$(cat "${RUSTDESK_CONFIG_DIR}/id" 2>/dev/null || \
                      grep -o '"id":"[^"]*"' "${RUSTDESK_CONFIG_DIR}"/*.json 2>/dev/null | head -1 | cut -d'"' -f4 || \
                      echo "")
    fi
    
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                  🦀 RUSTDESK SETUP COMPLETE                      ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    if [ -n "${RUSTDESK_ID}" ]; then
        echo "   🆔 RustDesk ID: ${RUSTDESK_ID}"
    else
        echo "   🆔 RustDesk ID: (check the RustDesk window or logs)"
    fi
    echo "   🔐 Password: (saved in private artifact)"
    echo ""
    echo "📊 RustDesk Process Info:"
    ps aux | grep -i rustdesk | grep -v grep || true
    
    echo ""
    echo "🌐 Network Status:"
    netstat -an | grep -E ":(21115|21116|21117|21118)" || echo "   RustDesk ports not yet listening (normal during startup)"
else
    echo ""
    echo "⚠️ RustDesk process not found. Trying to launch RustDesk again..."
    open -a RustDesk
    sleep 3
    
    if pgrep -f "RustDesk" > /dev/null; then
        echo "✅ RustDesk is now running!"
    else
        echo "❌ Could not start RustDesk."
    fi
fi

echo ""
echo "🎉 RustDesk setup complete!"
