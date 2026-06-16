# Troubleshooting Guide

> Diagnose and resolve issues with Remote Desktop Solution. If you cannot find your problem here, open an issue on [GitHub](https://github.com/your-org/remote-desktop-solution/issues) with your log files attached.

---

## Table of Contents

1. [Log Locations](#1-log-locations)
2. [Debug Mode](#2-debug-mode)
3. [Installer Issues](#3-installer-issues)
4. [Services Not Starting](#4-services-not-starting)
5. [Black Screen on iPad](#5-black-screen-on-ipad)
6. [No Audio](#6-no-audio)
7. [High Latency](#7-high-latency)
8. [VideoDecoder Not Supported](#8-videodecoder-not-supported)
9. [Pointer Lock Not Working](#9-pointer-lock-not-working)
10. [Tailscale Not Connecting](#10-tailscale-not-connecting)
11. [GPU Encoding Errors](#11-gpu-encoding-errors)
12. [WebRTC ICE Failure](#12-webrtc-ice-failure)
13. [Common Error Codes](#13-common-error-codes)

---

## 1. Log Locations

Before diving into specific issues, collect the relevant logs.

| Component | Log File Path | Notes |
|-----------|---------------|-------|
| Sunshine (main) | `%APPDATA%\Sunshine\logs\sunshine.log` | Primary streaming log |
| Sunshine (errors) | `%APPDATA%\Sunshine\logs\sunshine-error.log` | Errors only |
| Moonlight Web Server | `%APPDATA%\RemoteDesktop\logs\web-server.log` | Rust server log |
| Moonlight Web Server | `%APPDATA%\RemoteDesktop\logs\web-server-error.log` | Errors only |
| Windows Event Log | Event Viewer → Windows Logs → Application | Windows service errors |
| Windows Event Log | Event Viewer → Windows Logs → System | Driver and hardware errors |
| Tailscale | `%APPDATA%\Tailscale\tailscale.log` | VPN/networking log |

### Opening the Logs Directory Quickly

Run this in PowerShell or the Run dialog (`Win+R`):
```powershell
explorer "$env:APPDATA\Sunshine\logs"
explorer "$env:APPDATA\RemoteDesktop\logs"
```

### Viewing Event Viewer

1. Press `Win+R`, type `eventvwr.msc`, press Enter.
2. Expand **Windows Logs** → **Application**.
3. Filter by Source: `Sunshine`, `RemoteDesktop`, or `tailscaled`.

---

## 2. Debug Mode

For verbose logging to diagnose hard-to-reproduce issues:

### Moonlight Web Server (Rust)

Set the `RUST_LOG` environment variable before starting the service:

```powershell
# Set for the current PowerShell session
$env:RUST_LOG = "debug"
& "C:\Program Files\RemoteDesktop\web-server.exe"
```

Or permanently via Windows environment variables:
1. Open **System Properties** → **Advanced** → **Environment Variables**.
2. Under **System variables**, click **New**.
3. Name: `RUST_LOG`, Value: `debug`
4. Restart the `RemoteDesktop-WebServer` service.

Available log levels (most verbose → least):
- `trace` — extremely verbose, every I/O operation
- `debug` — detailed internal state, WebRTC negotiation, ICE candidates
- `info` — normal operation (default)
- `warn` — warnings only
- `error` — errors only

### Sunshine

In the Sunshine dashboard (`https://localhost:47990`) → **Configuration** → **General**:
- Set **Minimum Log Level** to `Debug`.
- Logs appear in real time in the **Logs** tab and in the log files above.

---

## 3. Installer Issues

### Installer Fails to Start

**Symptom:** Double-clicking the installer does nothing, or it crashes immediately.

**Cause 1: UAC is disabled or restricted**  
The installer requires Administrator privileges.

**Fix:**
- Right-click the installer → **Run as administrator**.
- If UAC is disabled by Group Policy (corporate PC), contact your IT administrator.

**Cause 2: Antivirus blocking the installer**  
Some antivirus products quarantine unsigned or newly downloaded executables.

**Fix:**
1. Check your antivirus quarantine folder for the installer.
2. Temporarily disable real-time protection, run the installer, then re-enable.
3. Add the installer to the antivirus exclusion list.
4. Verify the SHA256 checksum against the release page to confirm the file is genuine.

**Cause 3: Missing Visual C++ Redistributable**

**Fix:** Download and install [Visual C++ Redistributable 2022](https://aka.ms/vs/17/release/vc_redist.x64.exe) from Microsoft, then re-run the installer.

### Installer Stops Midway

**Symptom:** Progress bar freezes or installer exits without finishing.

**Fix:**
1. Check the installer log: `%TEMP%\RemoteDesktopInstall.log`
2. Look for lines starting with `Error:` or `Failed:`.
3. Common causes: disk full, Sunshine already running (close it), network error downloading Tailscale MSI.

If Tailscale download fails:
- The installer downloads Tailscale during setup. Ensure your internet connection is active.
- If behind a corporate proxy, set the proxy before running:
  ```powershell
  $env:HTTPS_PROXY = "http://your-proxy:8080"
  ```

---

## 4. Services Not Starting

### Checking Service Status

```powershell
Get-Service -Name "SunshineService", "RemoteDesktop-WebServer", "tailscaled" |
  Select-Object Name, Status, StartType
```

### Starting Services Manually

```powershell
Start-Service -Name "SunshineService"
Start-Service -Name "RemoteDesktop-WebServer"
Start-Service -Name "tailscaled"
```

### Port Conflicts

Moonlight Web Server defaults to port **443** (redirected via Tailscale Funnel). If another service occupies this port:

```powershell
netstat -ano | findstr ":443 "
```

The last column is the PID. Find the process:
```powershell
Get-Process -Id <PID>
```

Sunshine uses these ports:
| Port | Protocol | Purpose |
|------|----------|---------|
| 47984 | TCP | RTSP (stream setup) |
| 47989 | TCP | HTTPS stream |
| 47990 | TCP | Web dashboard |
| 47998–48000 | UDP | Video/audio RTP |
| 48010 | TCP | Control channel |

Check for conflicts:
```powershell
netstat -ano | findstr ":47984 :47989 :47990 :47998 :47999 :48000 :48010"
```

### Firewall

Windows Firewall rules are added automatically by the installer. To verify:
```powershell
Get-NetFirewallRule -DisplayName "*Sunshine*" | Select-Object DisplayName, Action, Enabled
Get-NetFirewallRule -DisplayName "*RemoteDesktop*" | Select-Object DisplayName, Action, Enabled
```

If rules are missing, re-run the post-install script:
```powershell
powershell -File "C:\Program Files\RemoteDesktop\scripts\configure-firewall.ps1"
```

---

## 5. Black Screen on iPad

### Symptom

The browser connects to the server URL, the login succeeds, but the stream canvas shows only black (possibly with audio playing).

### Cause 1: HTTPS Certificate Not Trusted

WebRTC and canvas video rendering require a secure context (HTTPS). If the browser shows a certificate warning and you clicked "Proceed anyway," the browser may still block media.

**Fix:**
1. On the iPad, navigate to your Tailscale URL in Safari.
2. If there is any certificate warning, do **not** proceed to the site.
3. Verify Tailscale Funnel is active on the PC:
   ```powershell
   tailscale funnel status
   ```
4. If Funnel shows an error, re-enable it:
   ```powershell
   tailscale funnel 443
   ```
5. Tailscale Funnel provides a valid Let's Encrypt certificate — there should be no warnings once Funnel is active.

### Cause 2: GPU Encoder Returning Black Frames

The GPU encoder (NVENC/AMF/QSV) initialised but is encoding black frames.

**Fix:**
1. Check Sunshine logs for encoder errors.
2. Update your GPU driver.
3. Try switching to a different encoder in Sunshine dashboard → **Configuration** → **Streaming** → **Encoder**.

### Cause 3: Monitor is Off or Disconnected

Sunshine captures the physical GPU output. If the monitor is off or not connected, capture may return a black frame.

**Fix:**
- Use a virtual display adapter (e.g., HDMI dummy plug) if streaming a headless PC.
- Check Sunshine configuration → capture display index.

---

## 6. No Audio

### Symptom

Video streams correctly but there is no audio on the iPad.

### Cause 1: iOS Autoplay Policy (Most Common)

iOS requires a user gesture before audio can play.

**Fix:** After the stream starts and video is playing, **tap anywhere on the stream canvas once**. Audio will begin immediately.

### Cause 2: Wrong Audio Sink in Sunshine

Sunshine is capturing the wrong audio device.

**Fix:**
1. Open Sunshine dashboard → **Configuration** → **Audio**.
2. Set **Audio Sink** to the device you want to capture (e.g., "Speakers (Realtek High Definition Audio)").
3. Save and reconnect.

### Cause 3: Remote PC Muted

**Fix:** On the Windows PC, click the speaker icon in the system tray and ensure the volume is not muted.

### Cause 4: AudioContext Not Created

The browser's AudioContext may not have initialised.

**Fix:**
1. Disconnect and reconnect the stream.
2. Ensure you tap the canvas immediately when the stream starts (before the autoplay lock engages more deeply).

---

## 7. High Latency

### Symptom

Noticeable delay between input (keyboard/trackpad) and visual response on the iPad screen, typically >150ms.

### Measuring Latency

In the app's settings panel (gear icon), enable **Statistics Overlay**. This shows:
- Frame decode time (ms)
- RTT to server (ms)
- Jitter (ms)
- Network path (direct / relay)

### Cause 1: WiFi Instead of Ethernet on PC

**Fix:** Connect the Windows PC to the router via Ethernet cable. Wi-Fi introduces variable latency (jitter) that degrades streaming quality significantly.

### Cause 2: Tailscale Relay Instead of Direct Connection

When a direct peer-to-peer connection cannot be established, Tailscale routes traffic through a DERP relay server, adding 20–100ms of latency.

**Diagnosis:**
```powershell
tailscale status
```
Look for your iPad device — it will say `relay` or `direct` next to the connection.

**Fix:**
1. Ensure both devices are connected to Tailscale.
2. Run `tailscale ping <ipad-ip>` from the PC — this attempts to establish a direct connection.
3. Check that UDP traffic is not blocked by your router/firewall.
4. If a corporate firewall is blocking UDP, consider using coturn as a TURN relay (see [WebRTC ICE Failure](#12-webrtc-ice-failure)).

### Cause 3: coturn TURN Relay Active

If WebRTC falls back to coturn, latency depends on coturn's location relative to both devices. If coturn is running on the same LAN as the PC, it should be fast.

**Diagnosis:** Check the Statistics Overlay for "TURN relay" indication.

### Cause 4: Encoding Preset Too Slow

Higher-quality encoder presets (e.g., NVENC `p7`) take longer to encode, adding latency.

**Fix:** In Sunshine → **Streaming**, switch to a faster preset:
- NVENC: `p1` (fastest) to `p4` (balanced)
- AMD AMF: `speed` or `balanced`
- Intel QSV: `veryfast`

### Cause 5: 2.4 GHz Wi-Fi on iPad

**Fix:** Ensure your iPad is connected to the 5 GHz band (or Wi-Fi 6/6E if available). 5 GHz has lower congestion and higher throughput.

---

## 8. VideoDecoder Not Supported

### Symptom

The browser shows an error: `VideoDecoder is not supported` or `Failed to configure decoder`.

### Cause 1: iPadOS Version Too Old

WebCodecs API requires **iPadOS 17.0** or later.

**Fix:** Update iPadOS: **Settings** → **General** → **Software Update**.

### Cause 2: Unsupported Codec Configuration

The HEVC configuration string requested by the server is not supported by the device's hardware decoder.

**Fix:**
1. The server should automatically detect the device and offer the appropriate codec. Check server logs for codec negotiation.
2. If HEVC is being offered to a pre-A9X device, this is a bug — open a GitHub issue.
3. As a workaround, force H.264 by adding `?codec=h264` to the URL.

### Cause 3: Browser Not Safari on iPadOS 17

Only Safari on iPadOS 17+ supports hardware VideoDecoder for HEVC. Chrome and Firefox on iOS use WebKit and should work identically to Safari, but verify the iOS version.

**Fix:** If on a Mac, use Chrome 116+ on macOS 13 (Ventura) for HEVC hardware decode support.

---

## 9. Pointer Lock Not Working

### Symptom

Tapping the stream canvas does not capture the cursor; trackpad continues to move the local iPad cursor.

### Cause 1: Not on HTTPS

Pointer Lock API requires a secure context.

**Fix:** Confirm the URL starts with `https://`. See [Black Screen](#5-black-screen-on-ipad) for Tailscale Funnel setup.

### Cause 2: Browser Prompt Dismissed

The browser shows a pointer lock confirmation dialog that times out after ~5 seconds.

**Fix:** Tap the canvas, then **immediately** tap **Allow** in the browser dialog.

### Cause 3: Keyboard Shortcut Conflict

A keyboard shortcut may be interfering with pointer lock.

**Fix:**
1. Disable Keyboard Lock in app settings.
2. Try without any hardware keyboard connected.
3. Reconnect and try pointer lock again.

### Cause 4: Stage Manager or Split View Active

Pointer lock requires the app to be the focused, full-screen window.

**Fix:** Use the app in full-screen mode (not Stage Manager or Split View) for reliable pointer lock.

---

## 10. Tailscale Not Connecting

### Symptom

Tailscale system tray icon is red/orange, or `tailscale status` shows `stopped` or `NeedsLogin`.

### Cause 1: Authentication Expired

**Fix:**
```powershell
tailscale login
```
Follow the URL or scan the QR code to re-authenticate.

### Cause 2: Tailscale Service Not Running

**Fix:**
```powershell
Start-Service tailscaled
tailscale up
```

### Cause 3: Funnel Not Configured

**Fix:** Re-run the funnel setup script:
```powershell
powershell -File "C:\Program Files\RemoteDesktop\scripts\funnel-setup.ps1"
```

Or manually:
```powershell
tailscale funnel 443
```

Verify:
```powershell
tailscale funnel status
```

### Cause 4: Corporate Network Blocking WireGuard

**Fix:** Tailscale can fall back to TCP port 443. Enable this:
```powershell
tailscale set --exit-node-allow-lan-access
```
Or in the Tailscale admin console, enable "Override local DNS".

---

## 11. GPU Encoding Errors

### Symptom

Sunshine logs show `NVENC error`, `AMF error`, or similar; stream does not start or shows corrupted video.

### Cause 1: Outdated GPU Driver

**Fix:**
- NVIDIA: Update via GeForce Experience or [nvidia.com/drivers](https://www.nvidia.com/drivers)
- AMD: Update via AMD Software (Adrenalin) or [amd.com/support](https://www.amd.com/support)
- Intel: Update via Intel Driver & Support Assistant

Minimum driver versions:
| GPU | Minimum Driver |
|-----|----------------|
| NVIDIA | 530.x (Game Ready) |
| AMD | Adrenalin 23.1.1 |
| Intel Arc | 31.0.101.4575 |

### Cause 2: Another Application Holding the Encoder

NVENC has a session limit per GPU (2 sessions on consumer cards, unlimited on RTX/Quadro).

**Fix:**
1. Close other applications using hardware encoding (OBS, NVIDIA Shadowplay, game recordings).
2. Restart Sunshine service.

### Cause 3: Fallback to Software Encoder

If hardware encoding fails, Sunshine automatically falls back to software encoding (libx264). This increases CPU usage significantly.

**Check:** In Sunshine logs, look for `Falling back to software encoder`.

**Fix:**
1. Resolve the hardware encoder error first.
2. Explicitly set the encoder in Sunshine dashboard to NVENC/AMF/QSV.
3. If software encoding is unavoidable, lower the resolution and frame rate to reduce CPU load.

---

## 12. WebRTC ICE Failure

### Symptom

The stream connection attempt fails with `ICE connection failed` or `ICE gathering timeout`.

### Understanding ICE

WebRTC uses ICE (Interactive Connectivity Establishment) to find the best network path between the PC and iPad. It tries:
1. **Host candidates** — direct LAN connection
2. **Server-reflexive (STUN)** — direct internet connection via NAT traversal
3. **Relay (TURN)** — via coturn relay server

### Cause 1: coturn Not Running

If coturn is installed but not running, TURN candidates are unavailable.

**Fix:**
```powershell
Get-Service -Name "coturn"
Start-Service -Name "coturn"
```

Or check Docker (if using Docker coturn):
```powershell
docker ps | findstr coturn
docker start coturn
```

### Cause 2: Firewall Blocking UDP Ports 40000–40010

coturn uses UDP port range 40000–40010 for relay traffic.

**Fix:**
```powershell
# Add firewall rule for coturn relay ports
New-NetFirewallRule -DisplayName "coturn TURN relay UDP" `
  -Direction Inbound -Protocol UDP -LocalPort 40000-40010 `
  -Action Allow -Profile Any
```

### Cause 3: STUN Server Unreachable

If the STUN server configured in coturn or Sunshine is unreachable, ICE gathering fails.

**Fix:**
1. Check `coturn.conf` for the STUN/TURN server address.
2. Test STUN reachability: run `tailscale ping` to check basic connectivity.
3. Use Tailscale's built-in DERP relay as a fallback (it activates automatically).

### Cause 4: Symmetric NAT

Some enterprise/cellular networks use symmetric NAT, which prevents STUN from working. TURN relay is required.

**Fix:** Ensure coturn is running and the firewall allows its relay ports (see above).

---

## 13. Common Error Codes

| Error Code / Message | Meaning | Fix |
|----------------------|---------|-----|
| `ERR_CERT_AUTHORITY_INVALID` | HTTPS certificate not trusted | Ensure Tailscale Funnel is active; re-run funnel setup |
| `ERR_CONNECTION_REFUSED` | Web server not running or wrong port | Start `RemoteDesktop-WebServer` service; check port 443 |
| `ICE failed` | WebRTC peer connection failed | Check coturn, firewall UDP 40000-40010 |
| `VideoDecoder: NotSupportedError` | Codec not supported by device | Update iPadOS; check device compatibility table |
| `401 Unauthorized` | Wrong username or password | Re-enter credentials; reset password via Sunshine dashboard |
| `503 Service Unavailable` | Sunshine not running | Start `SunshineService` |
| `NVENC_ERR_OUT_OF_MEMORY` | GPU VRAM exhausted | Close other GPU-intensive apps; lower resolution |
| `NvFBCCreateInstance failed` | NvFBC capture API unavailable | Update NVIDIA driver; ensure GPU is not in TCC mode |
| `Tailscale: NeedsLogin` | Tailscale authentication expired | Run `tailscale login` |
| `Tailscale: NoState` | Tailscale service not started | Run `Start-Service tailscaled` |
| `AudioContext was not allowed to start` | iOS autoplay policy | Tap the stream canvas after video starts |
| `pointer lock request failed` | Pointer lock denied or HTTP context | Ensure HTTPS; tap canvas and accept prompt quickly |
| `RUST_LOG=error [WARN] TLS handshake failed` | TLS cert mismatch or client using HTTP | Check Tailscale Funnel HTTPS cert is valid |
| `cargo: error: could not find Cargo.toml` | Build path misconfiguration | Ensure `cd moonlight-web/server` before `cargo build` |
| `NSIS: Error in script` | NSIS installer script error | Check NSIS version ≥ 3.09; review installer/build.ps1 |
| `ERROR_ELEVATION_REQUIRED` | Process needs Administrator rights | Right-click → Run as administrator |
