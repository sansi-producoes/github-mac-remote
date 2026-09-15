# 🍎 GitHub Mac Remote

> **Access Apple Silicon Macs (M1/M2/M3/M4) remotely through GitHub Actions**

Turn GitHub Actions runners into remotely accessible Macs. An alternative to services like MacStadium, using GitHub's infrastructure.

[![RustDesk Session](https://img.shields.io/badge/🦀_Start_Session-RustDesk-orange?style=for-the-badge)](../../actions/workflows/rustdesk-session.yml)

---

## ✨ Features

| Feature | Description |
|---------|-------------|
| 🖥️ **Real Mac ARM64** | Virtualized Mac Mini with Apple Silicon |
| 🦀 **RustDesk** | Remote access without complex setup |
| 🎮 **Parsec Pre-installed** | Optional low-latency alternative |
| 🔐 **Admin User Created** | Dedicated admin account for system authentication |
| ⏱️ **Configurable Sessions** | From 1h to 6h per session |
| 🔗 **Extended Sessions** | Auto-chaining for >6h sessions |
| 📊 **Multiple Sizes** | Standard, Large, XLarge |
| 🔒 **Secure Credentials** | Passwords never shown in logs |
| 🌐 **Unique IP Guarantee** | Each session gets a fresh, unique IP via Cloudflare WARP |
| 🧭 **OpenWrt exit** | Optional OpenWrt VM inside the Mac; Safari/Chrome leave via Azure IP |
| 📋 **IP Tracking** | Tracks IP history per user to detect duplicates |

---

## 🚀 Quick Start

### Step 1: Fork or Clone

```bash
# Clone the repository
git clone https://github.com/brunusansi/github-mac-remote.git
```

Or **Fork** to your account/organization.

### Step 2: Install RustDesk on your computer

Download from: **https://rustdesk.com/download**

| System | Download |
|--------|----------|
| Windows | [rustdesk-x86_64.exe](https://github.com/rustdesk/rustdesk/releases/latest) |
| macOS Intel | [rustdesk-x86_64.dmg](https://github.com/rustdesk/rustdesk/releases/latest) |
| macOS Apple Silicon | [rustdesk-aarch64.dmg](https://github.com/rustdesk/rustdesk/releases/latest) |
| Linux | [.deb](https://github.com/rustdesk/rustdesk/releases/latest) / [.AppImage](https://github.com/rustdesk/rustdesk/releases/latest) |

### Step 3: Start a session

1. Go to **Actions** → **"🦀 RustDesk Mac Session"**
2. Click **"Run workflow"**
3. Configure:
   - **Duration**: Session time (1-6 hours)
   - **macOS Version**: Choose 14 (Sonoma), 15 (Sequoia), or 26 (Tahoe beta)
   - **Runner size**: Mac size (see table below)
   - **Unique IP**: Enable to guarantee a fresh IP via Cloudflare WARP VPN
   - **OpenWrt exit**: default **on** — boots OpenWrt inside the Mac and sends Safari/Chrome through it. WARP is skipped in this mode.
4. Click **"Run workflow"**

### Step 4: Connect

1. Wait for the workflow to reach **"Keep Session Alive"** step
2. In the **logs**, see the **RustDesk ID** (9 digits)
3. Download the **artifact** `credentials-<your-username>-<run-id>` from the Summary tab
4. Open the file to see both **passwords** (RustDesk and macOS)
5. In **RustDesk**, enter the ID and RustDesk password
6. **Connected!** 🎉

> 🔒 **Security**: Passwords do NOT appear in logs. Only in the private artifact.

---

## 🎮 Parsec (Optional)

**Parsec is pre-installed** on all sessions for optional use. If you prefer Parsec's lower latency:

1. Connect via RustDesk first
2. Open **Parsec** from Applications
3. Log in with your Parsec account
4. When prompted for permissions (Input Monitoring, Screen Recording):
   - **User:** `yourname` (the admin user created by the workflow)
   - **Password:** Use the macOS password from the credentials file
5. Enable hosting in Parsec settings
6. Connect from your other device!

> ℹ️ The workflow creates a dedicated admin user (`yourname`) that appears in Users & Groups and can authenticate in Privacy & Security dialogs.

---

## 📊 Runner Sizes

| Tier | Runner | vCPUs | RAM | Chip | Plans |
|------|--------|-------|-----|------|-------|
| **Standard** | `macos-{version}` | 3 | 7 GB | M1 | Free, Pro, Team, Enterprise |
| **Large** | `macos-{version}-large` | 12 | 30 GB | M1 Pro | Team, Enterprise |
| **XLarge** | `macos-{version}-xlarge` | 24 | 70 GB | M1 Max | Enterprise |

> ⚠️ **Note:** Some "large" runners may use Intel architecture. The system auto-detects CPU type and downloads the correct binaries.

---

## 🍎 macOS Versions

| Version | Codename | Status | Notes |
|---------|----------|--------|-------|
| **14** | Sonoma | ✅ Stable | Default, M1 ARM64 |
| **15** | Sequoia | ✅ Available | Newer features |
| **26** | Tahoe | ⚠️ Beta | Latest beta, may be unstable |

> 💡 **Tip**: Use macOS 14 for maximum stability. Use newer versions to test compatibility with upcoming macOS releases.

### Larger Runners (Large/XLarge)

To use larger runners, your organization needs a **Team** or **Enterprise** GitHub plan.

**How to enable larger runners:**

1. Go to **Settings** → **Actions** → **Runners**
2. Under "Larger runners", configure available runners
3. `macos-14-large` and `macos-14-xlarge` runners will become available

> 💡 **Tip**: Large/XLarge runners are ideal for iOS app compilation, simulators, and heavy tasks.

---

## 🌐 Unique IP Guarantee

Each session can be configured to have a **guaranteed unique IP address**. This is useful for:

- 🔒 Avoiding IP-based rate limits or bans
- 🆕 Ensuring each machine/user gets a fresh IP
- 📊 Tracking which IPs were used by whom

### How It Works

1. **IP Detection**: Every session detects and logs its public IP
2. **IP History**: IPs are tracked per user and stored in cache
3. **Duplicate Warning**: System alerts if an IP was previously used
4. **VPN Rotation**: Enable "Unique IP" to route through Cloudflare WARP for a different IP

### Enable Unique IP

When starting a workflow, set **"Unique IP"** to `true`:

| Option | Description |
|--------|-------------|
| `false` (default) | Uses GitHub's default IP (may repeat) |
| `true` | Routes through Cloudflare WARP VPN for unique IP |

### IP Information in Credentials

The credentials artifact includes:

```
🌐 Network Information:
  Public IP:  203.0.113.42
  Location:   San Francisco, US
  Provider:   AS13335 Cloudflare
  WARP VPN:   true
```

> ⚠️ **Note**: Even with "Unique IP" enabled, Cloudflare WARP IPs come from a shared pool. For truly dedicated IPs, consider using a paid VPN service.

---

## 🧭 OpenWrt exit (inside the Mac)

When **OpenWrt exit** is `true` (the default), the job boots an OpenWrt VM with QEMU on the same Apple Silicon runner and points Safari/Chrome at `127.0.0.1:13128`. Traffic from those apps leaves through OpenWrt and still uses the runner's **Azure** public IP. WARP is skipped in this mode so the two tunnels do not fight.

| Path | What happens |
|------|----------------|
| Safari / Chrome / most GUI apps | System HTTP/HTTPS proxy → OpenWrt tinyproxy → Azure IP |
| GitHub Actions / artifact upload | Direct. `HTTP_PROXY` is **not** exported |
| RustDesk | Direct. SOCKS is left off; GitHub/RustDesk/Apple are in the bypass list |

The first boot can take a few minutes (Homebrew QEMU + OpenWrt). If the VM fails, the script logs a warning and the RustDesk session still starts.

Manual SOCKS5 for a specific app: `127.0.0.1:11080`.

---

## ⏱️ Time Limits

| Plan | Minutes/month | Max per session |
|------|---------------|-----------------|
| **Free** | 2,000 min | 6 hours |
| **Pro** | 3,000 min | 6 hours |
| **Team** | 3,000 min | 6 hours |
| **Enterprise** | Custom | 6 hours |

> ⚠️ **Important**: macOS runners consume minutes at a **10x rate** on Free/Pro plans.
> Example: 1 hour of use = 10 minutes consumed from quota.

### Extended Sessions (>6 hours)

Use the **"🔗 Extended Mac Session"** workflow for longer sessions:

1. Set `max_chains` (max 3 = 18 hours total)
2. System automatically starts new session before timeout
3. New credentials are generated for each chain
4. ~30 seconds downtime between chains

---

## 🦀 Why RustDesk?

We tested several remote access options. Only **RustDesk** works reliably on GitHub Actions VMs:

| Method | Status | Reason |
|--------|--------|--------|
| **RustDesk** | ✅ Works | Uses its own screen capture method |
| VNC | ❌ Doesn't work | Screen Sharing blocked on VMs |
| Parsec (auto) | ❌ Doesn't work | Requires GUI permissions unavailable on VMs |
| Parsec (manual) | ✅ Works | Can be configured manually via RustDesk |

### RustDesk Advantages

- ✅ **No tunnel setup** - Uses relay servers automatically
- ✅ **No account needed** - Just ID and password
- ✅ **Cross-platform** - Windows, macOS, Linux, iOS, Android
- ✅ **Low latency** - Optimized for remote control
- ✅ **Open source** - Free with no vendor lock-in
- ✅ **Audio and file transfer** - Advanced features included

---

## 🔐 Security & Privacy

This project was built with **security in mind**, especially for multi-user environments.

### 🛡️ Credential Protection

| Feature | Implementation |
|---------|----------------|
| **Masked Passwords** | Uses `::add-mask::` - passwords NEVER appear in logs |
| **Private Artifact** | Credentials saved in downloadable artifact, not in logs |
| **User Identification** | Artifact named with initiating user: `credentials-<user>-<run-id>` |
| **Dedicated Admin User** | Creates `yourname` admin user for Privacy & Security dialogs |
| **Ephemeral Session** | Everything is destroyed when workflow ends |
| **Unique Credentials** | Each session generates new ID and passwords |

### 🔒 User Isolation

In repositories with multiple collaborators:

- **Each user** can identify their own artifact by name
- **Passwords don't leak** in public workflow logs
- **Sessions are independent** - each run has unique credentials

### 📋 Security Flow

```
1. User starts workflow
   ↓
2. Admin user 'yourname' created with UID >= 501 (visible in GUI)
   ↓
3. macOS password generated for admin user (12 alphanumeric characters)
   ↓
4. RustDesk password generated (12 alphanumeric characters)
   ↓
5. Both passwords masked with ::add-mask:: (won't appear in any log)
   ↓
6. Credentials saved to file inside artifact
   ↓
7. Artifact named: credentials-{user}-{run_id}
   ↓
8. Only those with repository access can download artifacts
```

### ⚠️ Considerations

| Scenario | Security Level |
|----------|----------------|
| **Private Repository** | 🟢 High - Only collaborators see artifacts |
| **Public Repository** | 🟡 Medium - Anyone can download artifacts |
| **Org with multiple members** | 🟢 High - Each downloads only their artifact |

### 📌 Recommendations

1. **Use a private repository** for maximum security
2. **Don't share** the credentials file
3. **Sessions are temporary** - credentials expire when workflow ends
4. **For organizations**: Each member should only download artifacts with their name

---

## 📁 Project Structure

```
.
├── .github/
│   └── workflows/
│       ├── rustdesk-session.yml   # RustDesk session (main)
│       └── extended-session.yml   # Session with chaining
├── scripts/
│   ├── setup-rustdesk.sh         # Configures RustDesk
│   ├── install-parsec.sh         # Installs Parsec (optional)
│   ├── keep-alive.sh             # Keeps session active
│   ├── system-info.sh            # System information
│   ├── ip-manager.sh             # IP detection and tracking
│   ├── setup-warp.sh             # Cloudflare WARP VPN setup
│   └── setup-openwrt.sh          # OpenWrt VM + localhost HTTP proxy
├── configs/
│   └── hardware-tiers.json       # Hardware configurations
└── README.md
```

---

## ❓ Troubleshooting

### "RustDesk won't connect"

1. Check if the workflow is still on the "Keep Session Alive" step
2. Confirm the ID and password are correct
3. Test your internet connection
4. Wait a few seconds and try again

### "Session ended early"

1. GitHub has a maximum 6h timeout per job
2. Use "Extended Session" for longer sessions
3. Check if keep-alive is generating output in logs

### "Black screen or unresponsive"

1. Wait a few seconds - the VM may be initializing
2. Try moving the mouse or pressing a key
3. If it persists, cancel and start a new session

### "Large/XLarge runners not showing"

1. Check if your organization has a Team or Enterprise plan
2. Configure larger runners in Settings → Actions → Runners
3. Runners need to be enabled for the repository

### "Parsec permissions not working"

1. When the authentication dialog appears, use:
   - **User:** `yourname` (not Anka or runner)
   - **Password:** The macOS password from the credentials file
2. The user `yourname` should appear in Users & Groups as an Admin
3. If the user doesn't appear, the workflow may have failed - check the logs

---

## ⚖️ Responsible Use

This project is for **legitimate development and testing**:

- ✅ Testing iOS/macOS apps
- ✅ Occasional development work
- ✅ CI/CD requiring macOS environment
- ✅ Swift/Xcode project compilation
- ❌ 24/7 usage (use MacStadium for that)
- ❌ Mining or abusive workloads

⚠️ GitHub may suspend accounts that abuse resources.

---

## 🔧 Advanced Configuration

### Credentials Included

Each session provides two sets of credentials in the artifact:

| Credential | Purpose |
|------------|---------|
| **macOS Admin User (`yourname`)** | System authentication (Privacy & Security, app installs) |
| **RustDesk ID + Password** | Remote desktop connection |

> 💡 The admin user `yourname` is created specifically to authenticate in GUI dialogs. It appears in Users & Groups alongside the default Anka user.

### Environment Variables

Workflows use these variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `SESSION_DURATION` | Duration in hours | 2 |
| `MACOS_VERSION` | macOS version (14, 15, 26) | 14 |
| `CURRENT_IP` | Public IP address of the session | Auto-detected |
| `IP_CITY` | City location of the IP | Auto-detected |
| `IP_COUNTRY` | Country of the IP | Auto-detected |
| `WARP_ENABLED` | Whether Cloudflare WARP VPN is active | false |
| `OPENWRT_ENABLED` | Whether the in-Mac OpenWrt exit is active | false |
| `OPENWRT_PROXY` | Local HTTP proxy used by Safari/Chrome | `127.0.0.1:13128` |
| `OPENWRT_EGRESS_IP` | Public IP seen through OpenWrt | Auto-detected |
| `IP_IS_DUPLICATE` | Whether this IP was used before | false |
| `RUSTDESK_PASSWORD` | RustDesk password (auto-generated) | Random |
| `MAC_PASSWORD` | macOS user password (auto-generated) | Random |

### Customization

To customize behavior, edit the workflow at `.github/workflows/rustdesk-session.yml`.

---

## 📄 License

MIT License - Use freely, but at your own risk.

---

## 🙏 Credits

- **GitHub Actions** - Runner infrastructure
- **RustDesk** - Open-source remote desktop software
- **Parsec** - Low-latency game streaming technology

---

<p align="center">
  <b>Made with ❤️ for the community</b><br>
  <sub>⭐ Star if this project helped you!</sub>
</p>
