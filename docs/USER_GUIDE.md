# User Guide — Remote Desktop Solution

> Stream your Windows PC to your iPad via WebRTC, with hardware-accelerated encoding and a native-feel PWA experience.

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [System Requirements](#2-system-requirements)
3. [Installation](#3-installation)
4. [Connecting from iPad](#4-connecting-from-ipad)
5. [Performance Tuning](#5-performance-tuning)
6. [Using Magic Keyboard and Trackpad](#6-using-magic-keyboard-and-trackpad)
7. [Sunshine Dashboard](#7-sunshine-dashboard)
8. [Tailscale Settings](#8-tailscale-settings)
9. [Updating](#9-updating)
10. [Uninstalling](#10-uninstalling)

---

## 1. Introduction

**Remote Desktop Solution** lets you stream your Windows desktop to an iPad in real time using WebRTC — the same low-latency protocol used by video-calling apps. It combines three open-source components:

| Component       | Technology               | Purpose                                        |
|-----------------|--------------------------|------------------------------------------------|
| Sunshine        | C++, NVENC / AMF / QSV   | Screen capture + hardware-accelerated encoding |
| Moonlight-Web   | Rust + TypeScript        | Browser-based WebRTC client (Safari / iPad)    |
| Tailscale       | WireGuard mesh VPN       | Secure end-to-end networking + HTTPS           |
| coturn          | Docker (optional)        | TURN relay fallback for restrictive networks   |

### Architecture Overview

```
  ┌─────────────────────────────────────────────┐
  │              Windows PC (Host)               │
  │                                              │
  │  ┌──────────┐   RTSP/SDP    ┌────────────┐  │
  │  │ Sunshine │◄─────────────►│ Moonlight  │  │
  │  │ (capture │               │ Web Server │  │
  │  │  encode) │               │  (Rust)    │  │
  │  └──────────┘               └─────┬──────┘  │
  │                                   │ HTTPS    │
  └───────────────────────────────────┼─────────┘
                                      │
                              ┌───────▼────────┐
                              │   Tailscale     │
                              │  (WireGuard)    │
                              │  + Funnel HTTPS │
                              └───────┬─────────┘
                                      │ WireGuard / HTTPS
                             ┌────────▼──────────┐
                             │       iPad         │
                             │  Safari 17+ / PWA  │
                             │  WebRTC decode     │
                             └────────────────────┘

Optional TURN relay (coturn) for NAT traversal:
  PC ──UDP 40000-40010──► coturn ──UDP──► iPad
```

The installer sets up all services automatically and configures Tailscale Funnel to provide a trusted HTTPS URL without any port forwarding or router changes.

---

## 2. System Requirements

### Windows PC (Host)

| Requirement      | Minimum                                  | Recommended                        |
|------------------|------------------------------------------|------------------------------------|
| OS               | Windows 10 version 1903 (build 18362)    | Windows 11 22H2 or later           |
| GPU              | NVIDIA GTX 1000 series, AMD RX 500, or Intel 6th-gen integrated (Quick Sync) | NVIDIA RTX 2000+ |
| RAM              | 8 GB                                     | 16 GB                              |
| CPU              | Intel Core i5 (6th gen) / AMD Ryzen 5    | Intel Core i7 / AMD Ryzen 7        |
| Network          | 100 Mbps Ethernet (LAN) or 5 GHz Wi-Fi  | Gigabit Ethernet                   |
| Disk             | 500 MB free for installation             | 1 GB free                          |
| GPU Driver       | NVIDIA 530+, AMD Adrenalin 23.x+, Intel Arc 31.x+ | Latest stable driver        |

> **Note:** A GPU with hardware video encoding is strongly recommended. Software encoding via libx264 is available as a fallback but will use significant CPU and produce higher latency.

### iPad (Client)

| Requirement  | Minimum                                             | Recommended                         |
|--------------|-----------------------------------------------------|-------------------------------------|
| Model        | iPad mini 6, iPad Air (3rd gen), iPad Pro (any)     | iPad Air M1 / iPad Pro M1 or newer  |
| iPadOS       | iPadOS 17.0                                         | iPadOS 17.4 or later                |
| Browser      | Safari 17.0                                         | Safari 17.4 or later                |
| Network      | 802.11ac (Wi-Fi 5) 5 GHz                            | Wi-Fi 6 / Ethernet via USB-C hub    |

> Safari is required for WebRTC with hardware HEVC decode. Chrome and Firefox on iOS share Safari's WebKit engine and will also work, but lack Pointer Lock API support needed for mouse input.

---

## 3. Installation

### Step 1: Download the Installer

1. Go to the [GitHub Releases page](https://github.com/your-org/remote-desktop-solution/releases/latest).
2. Download the latest `RemoteDesktopSetup-vX.X.X.exe` file.
3. Optionally verify the SHA256 checksum:
   ```powershell
   certutil -hashfile RemoteDesktopSetup-v1.0.0.exe SHA256
   ```
   Compare the output against the `.sha256` file in the same release.

### Step 2: Run as Administrator

1. Right-click `RemoteDesktopSetup-vX.X.X.exe` and choose **Run as administrator**.
2. If Windows Defender SmartScreen shows a warning, click **More info** → **Run anyway**.
   - The installer is signed with a code-signing certificate (release builds). If your build is unsigned (developer build), this warning is expected.
3. Click **Yes** at the UAC prompt.

### Step 3: Follow the Setup Wizard

The installer wizard proceeds through the following pages:

#### Page 1 — Welcome
Review the license agreement (GPL-3.0) and click **I Agree**.

#### Page 2 — Choose Components
Select which components to install:
- **Sunshine** (required) — screen capture and streaming engine
- **Moonlight Web Server** (required) — WebRTC browser interface
- **Tailscale** (required) — secure networking
- **coturn TURN server** (optional) — improves connectivity through strict NATs
- **Autostart on Login** (recommended)

#### Page 3 — Create Admin Account
Enter a username and password for the Sunshine dashboard. This account is used to:
- Log in to the stream from your iPad
- Access the Sunshine management UI at `https://localhost:47990`

Keep these credentials secure — they control access to your PC.

#### Page 4 — Tailscale Login
A QR code will appear. Scan it with your iPhone/iPad or visit the displayed URL on any device to authenticate with Tailscale.

- Log in with Google, Microsoft, GitHub, or a Tailscale account.
- After authentication, Tailscale will assign your PC a stable hostname (e.g., `my-pc.tail12345.ts.net`).
- The installer automatically enables **Tailscale Funnel**, which provides a publicly routable HTTPS URL.

> **Privacy note:** Tailscale Funnel makes your Moonlight Web server accessible over HTTPS from the internet, but it is protected by the username and password you created in the previous step.

#### Page 5 — GPU Detection
The installer scans for compatible GPUs and configures Sunshine with the optimal encoder:

| GPU Vendor | Encoder Used |
|------------|--------------|
| NVIDIA     | NVENC (H.264 + HEVC) |
| AMD        | AMF (H.264 + HEVC) |
| Intel      | QSV (H.264 + HEVC) |
| None found | Software (libx264, H.264 only) |

#### Page 6 — Summary
The installer displays your **Tailscale HTTPS URL** — for example:
```
https://my-pc.tail12345.ts.net
```
**Write this URL down or send it to yourself.** You will use it on your iPad.

Click **Install** to proceed. Installation takes 2–5 minutes.

#### Page 7 — Completion
Click **Finish**. Services start automatically. A system tray icon indicates Tailscale is connected.

---

## 4. Connecting from iPad

### Step 1: Open Safari

On your iPad, open **Safari** and navigate to your Tailscale HTTPS URL:
```
https://my-pc.tail12345.ts.net
```

> **Important:** You must use the full `https://` URL. HTTP will not work for WebRTC or Pointer Lock.

### Step 2: Enter Credentials

The Moonlight Web login page will appear. Enter the username and password you created during installation, then tap **Sign In**.

### Step 3: Add to Home Screen (PWA)

For the best full-screen experience, install the app as a Progressive Web App:

1. Tap the **Share** button (box with upward arrow) in Safari's toolbar.
2. Scroll down and tap **Add to Home Screen**.
3. Optionally rename the app (default: "Remote Desktop").
4. Tap **Add** in the top-right corner.

The app icon will appear on your Home Screen. Launch it from there for a true full-screen, no-browser-chrome experience.

> **Stage Manager users:** The PWA works in Stage Manager but pointer lock will exit if you switch windows. See [IPAD_SETUP.md](./IPAD_SETUP.md) for details.

### Step 4: Start Streaming

1. Open the app from your Home Screen (or directly in Safari).
2. The stream preview will appear. Tap **Connect** or tap anywhere on the stream canvas.
3. You will be prompted to allow pointer lock — tap **Allow** (or **Lock**).
4. Your Windows desktop is now live on your iPad.

> **First audio:** Tap anywhere on the stream canvas after it starts to enable audio. This is required by iOS's autoplay policy and only needs to be done once per session.

### Connection Status Indicators

| Icon | Meaning |
|------|---------|
| Green dot | Connected, streaming |
| Yellow dot | Connecting / buffering |
| Red dot | Disconnected — check network |
| Shield icon | End-to-end encrypted via Tailscale |

---

## 5. Performance Tuning

### LAN (Same Network) Settings

When your iPad and PC are on the same Wi-Fi network, Tailscale will typically establish a **direct peer-to-peer connection**, bypassing any relay servers. This gives the lowest possible latency.

Recommended Sunshine settings for LAN:
- **Resolution:** 1920×1080 (1080p)
- **Frame Rate:** 60 fps
- **Codec:** HEVC (H.265) — better quality per bit
- **Bitrate:** 20–50 Mbps (Wi-Fi 6 can handle 50 Mbps easily)
- **Encoder preset:** `p4` (balanced speed/quality) for NVENC; `balanced` for AMD

### Internet (Remote) Settings

When streaming over the internet (e.g., from a coffee shop), available bandwidth is lower and latency is higher. Tailscale may route through a relay.

Recommended settings for remote streaming:
- **Resolution:** 1280×720 (720p) or 1920×1080 at lower bitrate
- **Frame Rate:** 30–60 fps
- **Codec:** HEVC (better compression) or H.264 (wider compatibility)
- **Bitrate:** 5–15 Mbps
- **Encoder preset:** `p6` (higher quality) for NVENC

### Adjusting Settings in Sunshine

1. Open `https://localhost:47990` on your Windows PC.
2. Log in with your admin credentials.
3. Go to **Configuration** → **Streaming**.
4. Adjust resolution, frame rate, and bitrate.
5. Click **Save** — changes take effect on the next stream session.

### Checking Tailscale Connection Quality

Run this on your PC to see if you have a direct or relayed connection:
```powershell
tailscale status
```
Look for `direct` or `relay` next to your iPad's entry. For lowest latency, a direct connection is preferred.

To force a direct connection attempt:
```powershell
tailscale ping <ipad-tailscale-ip>
```

### Network Recommendations

| Scenario         | Recommendation                                      |
|------------------|-----------------------------------------------------|
| PC on Wi-Fi      | Switch to Ethernet — dramatically reduces jitter    |
| 2.4 GHz Wi-Fi    | Switch iPad to 5 GHz or Wi-Fi 6 band               |
| High packet loss  | Lower bitrate; enable FEC in Sunshine config       |
| VPN interference | Ensure Tailscale is excluded from other VPN splits |

---

## 6. Using Magic Keyboard and Trackpad

### Keyboard

The Magic Keyboard works transparently when connected to your iPad via Smart Connector or Bluetooth. All keystrokes are forwarded to the remote Windows session.

**Relative vs Absolute Input Mode**

The Moonlight Web client supports two input modes:
- **Relative mode** (default): Mouse movements are translated as deltas — the remote cursor moves relative to where it is. This feels like a normal mouse.
- **Absolute mode**: Touch/tap coordinates map directly to the screen. Useful for apps that require clicking specific screen positions without pointer lock.

Toggle between modes using the on-screen toolbar: tap the cursor icon to switch.

**Useful Keyboard Shortcuts**

| Shortcut | Action |
|----------|--------|
| `Ctrl+Alt+Del` | Send to remote (opens Windows security screen) |
| `Win+D` | Show Windows desktop |
| `Alt+Tab` | Switch windows on remote PC |
| `Ctrl+C / Ctrl+V` | Copy/paste (within remote session) |
| `Fn+Delete` | Sends `Delete` key (not Backspace) |
| `Cmd+H` | Minimize on Mac-like keyboards |

> **Keyboard Lock (Experimental):** Enabling keyboard lock intercepts system shortcuts (e.g., `Cmd+Space`, `Cmd+Tab`) and sends them to the remote PC instead of handling them locally. This is experimental and may not work on all iPadOS versions. If it causes issues, disable it in the app settings and use the on-screen modifier keys.

### Trackpad

The Magic Keyboard's trackpad is supported in **pointer lock mode** when the stream canvas is tapped:

- **Single finger:** Move remote mouse cursor
- **Two-finger scroll:** Scroll in the remote session
- **Two-finger tap:** Right-click
- **Three-finger tap:** Middle-click
- **Pinch gesture:** Disabled in stream mode (would otherwise zoom the browser)

> **Note:** Pointer lock requires HTTPS (provided by Tailscale Funnel). If the stream is accessed over HTTP, the trackpad will not capture correctly.

### On-Screen Controls

If a hardware keyboard is not available, the toolbar at the bottom of the stream provides:
- Virtual keyboard toggle
- Modifier key buttons (Ctrl, Alt, Win, Shift)
- Special key buttons (Escape, Tab, Delete, F1–F12)
- Input mode toggle (relative / absolute)

---

## 7. Sunshine Dashboard

Sunshine is the screen capture and streaming engine running on your PC. Its web dashboard gives you fine-grained control over the streaming configuration.

### Accessing the Dashboard

Open a browser on your Windows PC and navigate to:
```
https://localhost:47990
```

Log in with the admin credentials you created during installation.

> The dashboard is only accessible from `localhost` by default for security. Do not expose port 47990 to the internet.

### Key Sections

#### Configuration → General
- **UPnP:** Disable if you are using Tailscale exclusively (no need for port forwarding).
- **Origin web UI allowed hosts:** Keep as `localhost` unless you need LAN dashboard access.
- **Log Level:** Set to `Debug` when troubleshooting.

#### Configuration → Streaming
| Setting | Description |
|---------|-------------|
| Resolution | Capture resolution (should match your monitor) |
| FPS | Target frame rate (30 or 60) |
| Bitrate (Kbps) | Target encoding bitrate |
| Codec | H.264, HEVC, or AV1 (AV1 requires RTX 4000+) |
| Encoder | NVENC, AMF, QSV, or Software |
| Audio Sink | Which audio device to capture |

#### Applications
Add custom applications to launch directly from the Moonlight client:
1. Click **Add** under the Applications tab.
2. Enter an app name (e.g., "Chrome", "Steam").
3. Set the executable path (e.g., `C:\Program Files\Google\Chrome\Application\chrome.exe`).
4. Optionally set arguments and working directory.
5. Save. The app will appear in the Moonlight client's app list.

#### Clients
View and manage paired devices:
- **Add client:** Initiate pairing from the Moonlight Web interface.
- **Revoke client:** Remove a device's access permanently.
- **List paired clients:** All devices that have successfully authenticated.

#### Logs
Real-time log output from Sunshine. Use this to diagnose connection failures, encoding errors, and audio issues. Log file locations:
- `%APPDATA%\Sunshine\logs\sunshine.log`
- `%APPDATA%\Sunshine\logs\sunshine-error.log`

---

## 8. Tailscale Settings

Tailscale manages secure networking between your PC and your iPad.

### Sharing Access with Others

You can share access to your Windows PC with other Tailscale users:

1. Open the [Tailscale admin console](https://login.tailscale.com/admin/machines).
2. Find your PC in the machine list.
3. Click the three-dot menu → **Share...**.
4. Enter the email address of the person you want to share with.
5. They will receive an invitation. Once they accept, they can reach your PC via its Tailscale IP or hostname.

> **Note:** Shared users can reach the Moonlight Web interface. They still need valid Sunshine credentials to start a stream.

### Revoking Access

To remove a shared user's access:
1. Open the [Tailscale admin console](https://login.tailscale.com/admin/machines).
2. Select your PC.
3. Click **Sharing** → find the user → **Remove**.

### Tailscale Funnel

Funnel makes your Moonlight Web server accessible over HTTPS without any router/firewall changes. It is enabled automatically by the installer.

To check Funnel status:
```powershell
tailscale funnel status
```

To temporarily disable Funnel:
```powershell
tailscale funnel off
```

To re-enable Funnel:
```powershell
tailscale funnel 443
```

Or re-run the funnel setup script:
```powershell
powershell -File "C:\Program Files\RemoteDesktop\scripts\funnel-setup.ps1"
```

### Checking Your Tailscale URL

Run the following on your PC to confirm your Tailscale hostname and Funnel URL:
```powershell
tailscale status
tailscale funnel status
```

The Funnel URL will be in the format:
```
https://my-pc.tail12345.ts.net
```

---

## 9. Updating

To update to a new version of Remote Desktop Solution:

1. Download the latest installer from the [GitHub Releases page](https://github.com/your-org/remote-desktop-solution/releases/latest).
2. Run the new installer as Administrator (right-click → **Run as administrator**).
3. The installer detects the existing installation and upgrades it in place.
4. Your Sunshine pairing database, credentials, and Tailscale authentication are preserved across updates.
5. Click **Finish** when the update completes. Services restart automatically.

> **Caution:** Do not manually delete Sunshine's `config.toml` or credential files before updating — the installer migrates settings automatically.

---

## 10. Uninstalling

To remove Remote Desktop Solution from your PC:

1. Open **Settings** → **Apps** → **Installed apps** (Windows 11) or **Control Panel** → **Programs** → **Uninstall a program** (Windows 10).
2. Find **Remote Desktop Solution** in the list.
3. Click **Uninstall** and follow the prompts.

The uninstaller removes:
- Sunshine and all associated services
- Moonlight Web Server service
- coturn (if installed)
- All config files under `%APPDATA%\Sunshine` and `C:\Program Files\RemoteDesktop`

**Tailscale is not uninstalled automatically** — it is a general-purpose VPN that may be used by other applications. To remove Tailscale separately, find it in the same Apps list and uninstall it.

> **Data preserved:** Your Windows user data, documents, and other files are not affected by the uninstaller.

---

*For help beyond this guide, see [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) or open an issue on [GitHub](https://github.com/your-org/remote-desktop-solution/issues).*
