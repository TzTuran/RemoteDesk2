# iPad Setup Guide

> Detailed iPad-specific configuration, hardware compatibility, and troubleshooting for Remote Desktop Solution.

---

## Table of Contents

1. [Supported Devices and OS Versions](#1-supported-devices-and-os-versions)
2. [Video Decode Capabilities by Hardware](#2-video-decode-capabilities-by-hardware)
3. [Adding the PWA to Your Home Screen](#3-adding-the-pwa-to-your-home-screen)
4. [Enabling Audio](#4-enabling-audio)
5. [Magic Keyboard Support](#5-magic-keyboard-support)
6. [Trackpad Behavior](#6-trackpad-behavior)
7. [Pointer Lock](#7-pointer-lock)
8. [Stage Manager Compatibility](#8-stage-manager-compatibility)
9. [Split View and Slide Over](#9-split-view-and-slide-over)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Supported Devices and OS Versions

### Fully Supported (Best Experience)

| Device | Chip | Notes |
|--------|------|-------|
| iPad Pro 12.9" (5th gen+) | M1 / M2 / M4 | Full 1080p60 HEVC, pointer lock, keyboard lock |
| iPad Pro 11" (3rd gen+) | M1 / M2 / M4 | Full 1080p60 HEVC, pointer lock, keyboard lock |
| iPad Air (5th gen+) | M1 / M2 | Full 1080p60 HEVC, pointer lock |
| iPad mini 6 | A15 Bionic | Full 1080p60 HEVC, pointer lock |

### Supported with H.264 Fallback

| Device | Chip | Notes |
|--------|------|-------|
| iPad Pro (1st–4th gen) | A9X–A14 | H.264 hardware decode via VideoToolbox; HEVC on A10X+ |
| iPad Air (3rd–4th gen) | A12–A14 | H.264 hardware decode; HEVC on A12+ |
| iPad (6th–9th gen) | A10–A14 | H.264 hardware decode |
| iPad mini 5 | A12 | H.264 + HEVC hardware decode |

### Limited Support (Software Fallback)

| Device | Chip | Notes |
|--------|------|-------|
| iPad Pro (2014, 1st gen) | A7 | Software decode (OpenH264 WASM), 720p30 max |
| iPad Air 2 | A8X | Software decode (OpenH264 WASM), 720p30 max |
| iPad mini 4 | A8 | Software decode (OpenH264 WASM), 720p30 max |

> Devices older than iPad mini 4 are not supported.

### Minimum Software Requirements

- **iPadOS:** 17.0 or later
- **Safari:** 17.0 or later (shipped with iPadOS 17)
- WebRTC, WebCodecs, and the Pointer Lock API are all required features; iPadOS 17 is the first version with full support.

---

## 2. Video Decode Capabilities by Hardware

The Moonlight Web client detects your device's hardware capabilities at runtime and selects the best available decoder automatically.

### HEVC (H.265) Hardware Decode

Available on **A9X and later** (iPad Pro 2016 and newer) via Apple's **VideoToolbox** framework. HEVC provides significantly better quality per bit than H.264 — at the same bitrate, you get sharper images with less compression artifacts.

The browser checks for HEVC support using:
```javascript
const hevcSupported = await VideoDecoder.isConfigSupported({
  codec: 'hev1.1.6.L120.B0',
  hardwareAcceleration: 'prefer-hardware'
});
```

### H.264 (AVC) Hardware Decode — Automatic Fallback

All iPads with an **A9 chip or newer** support H.264 hardware decode via VideoToolbox. When HEVC is not available, the server automatically switches to H.264.

The bitrate is automatically increased by ~40% to compensate for H.264's lower compression efficiency, maintaining comparable visual quality.

### Software Decode — OpenH264 WASM (Pre-A9X Devices)

On very old devices (pre-iPad Pro 2016), neither HEVC nor efficient H.264 hardware decode is available. The client falls back to a WebAssembly-compiled version of OpenH264.

Limitations in software decode mode:
- Maximum resolution: **720p (1280×720)**
- Maximum frame rate: **30 fps**
- CPU usage will be high — device may become warm
- Audio latency may increase

This mode is provided as a best-effort fallback. For a good streaming experience, a device with A9X or newer is strongly recommended.

### Codec Selection Summary

| Chip Generation | HEVC HW | H.264 HW | Software Fallback |
|-----------------|---------|----------|--------------------|
| A9X+ (2016+)    | ✓       | ✓        | ✓ (never needed)   |
| A9 (2015)       | ✗       | ✓        | ✓ (if H.264 fails) |
| A7/A8 (2013–2014) | ✗    | ✗        | ✓ (720p30 only)    |

---

## 3. Adding the PWA to Your Home Screen

Installing the app as a Progressive Web App removes the browser chrome (address bar, tabs) and gives a full-screen, app-like experience. This is strongly recommended.

### Step-by-Step

1. **Open Safari** on your iPad and navigate to your Tailscale URL:
   ```
   https://my-pc.tail12345.ts.net
   ```

2. **Sign in** with your username and password.

3. Tap the **Share button** — the rectangle with an arrow pointing upward, located in Safari's toolbar.
   - On iPad, this is in the top toolbar next to the URL bar.

4. In the Share sheet that slides up, scroll down until you see **"Add to Home Screen"** and tap it.

5. You will see a name field (default: "Remote Desktop" or the page title). You can rename it to anything (e.g., "My PC").

6. Tap **Add** in the upper-right corner of the dialog.

7. The icon will appear on your iPad's Home Screen.

### Launching the PWA

Tap the icon from your Home Screen. The app launches in **standalone mode**:
- No Safari browser chrome
- True full-screen (hides status bar in landscape mode)
- Separate app entry in the App Switcher
- Persists login session between launches

> **Tip:** In landscape orientation, the stream fills the entire screen. Rotate your iPad to landscape before tapping the stream to start.

---

## 4. Enabling Audio

**iOS enforces a strict autoplay policy:** audio cannot start until the user has interacted with the page. This is a browser security policy that applies to all web applications, not a limitation of Remote Desktop Solution.

### How to Enable Audio

1. Start the stream (tap **Connect** or tap the canvas).
2. Once the video is playing, **tap anywhere on the stream canvas**.
3. Audio will begin immediately after the tap.

This only needs to be done once per session. If you disconnect and reconnect, you may need to tap again.

### Audio Not Working?

See the [Troubleshooting](#10-troubleshooting) section. Common causes:
- Did not tap the canvas after connecting
- Sunshine's audio sink is configured to capture the wrong device
- The remote PC is muted

---

## 5. Magic Keyboard Support

The Apple Magic Keyboard (with or without trackpad) connects to iPad via the Smart Connector (Magic Keyboard for iPad) or Bluetooth.

### What Works

- All standard keys, including function row (F1–F12)
- Modifier keys: Shift, Ctrl, Alt/Option, Cmd (mapped to Win key on Windows)
- Arrow keys and navigation cluster
- Media keys (volume, brightness) are captured locally by iPadOS and **not** forwarded

### Keyboard Lock (Experimental)

Keyboard Lock is an experimental browser API that intercepts system-level key combinations and forwards them to the remote session. This allows shortcuts like `Cmd+Tab` or `Cmd+Space` to reach Windows rather than being handled by iPadOS.

**Status on iPadOS 17:** Partially supported. Some system shortcuts (e.g., `Cmd+H` for Home) cannot be intercepted and will always be handled by iPadOS.

**If Keyboard Lock causes issues** (e.g., keys stop responding, modifier keys get "stuck"):
1. Open the app's settings panel (gear icon in toolbar).
2. Toggle **Keyboard Lock** off.
3. Use the on-screen modifier key buttons for Ctrl, Alt, and Win key combinations.

### On-Screen Keyboard

If no hardware keyboard is attached:
- Tap the keyboard icon in the bottom toolbar to show the on-screen keyboard.
- The on-screen keyboard works for text input but lacks physical key feel.
- Use the modifier buttons in the toolbar for Ctrl+C, Ctrl+V, etc.

---

## 6. Trackpad Behavior

When a Magic Keyboard with trackpad is connected, the trackpad is captured by Pointer Lock and controls the remote mouse cursor directly.

### Gestures Supported

| Gesture | Action |
|---------|--------|
| One-finger move | Move remote cursor |
| One-finger tap | Left-click |
| Two-finger tap | Right-click |
| Three-finger tap | Middle-click |
| Two-finger scroll | Scroll up/down/left/right |
| Two-finger swipe left/right | Back/Forward (browser navigation) — **disabled** in stream mode |
| Pinch | **Disabled** in stream mode (would zoom browser) |

### Why Pinch is Disabled

In stream mode, the canvas is locked to the display resolution. Pinch-to-zoom on the stream would distort the video without actually zooming the remote desktop. If you need to zoom the remote desktop, use Windows' built-in Magnifier (`Win+Plus`).

---

## 7. Pointer Lock

**Pointer Lock** captures the trackpad (or finger input) and routes all movement directly to the remote session, hiding the local cursor. This is essential for a natural mouse feel.

### Enabling Pointer Lock

1. Tap the stream canvas once. A browser prompt will appear: **"[Site] wants to lock your pointer"**.
2. Tap **Allow** (or **Lock**).
3. The local cursor disappears. All trackpad movement now controls the remote cursor.

### Exiting Pointer Lock

- Press **Escape** on your keyboard. This releases pointer lock.
- On-screen: tap the **"Release Pointer"** button in the toolbar (appears when pointer lock is active).

### Requirements for Pointer Lock

- The page **must** be loaded over HTTPS. Tailscale Funnel provides this automatically.
- The user must have interacted with the page (tapped) before pointer lock can be requested.
- Pointer lock will not activate while the app is in a Safari tab that is not in the foreground.

---

## 8. Stage Manager Compatibility

Stage Manager is the iPadOS 16+ multitasking mode that allows multiple overlapping windows.

### What Works
- The Remote Desktop PWA runs in a resizable Stage Manager window.
- Video playback and audio work normally.
- The on-screen keyboard and toolbar work normally.

### Known Limitations
- **Pointer lock exits when switching windows.** If you tap another app's window, pointer lock is released. You must tap the stream canvas again to re-acquire it.
- **Window resizing does not change the stream resolution.** The stream runs at the configured resolution; the video is letterboxed/pillarboxed to fit the window.
- **Full-screen mode is unavailable in Stage Manager.** The stream fills the Stage Manager window, not the entire screen.

---

## 9. Split View and Slide Over

**Using Remote Desktop in Split View or Slide Over is not recommended.**

### Why

- Pointer lock cannot be maintained when the app is not in the primary (large) split.
- In Slide Over, the app window is too small for practical remote desktop use.
- Switching between Split View apps releases pointer lock, requiring a re-tap to resume.

If you need to reference another app while streaming, use Stage Manager instead — it provides a better experience with overlapping windows.

---

## 10. Troubleshooting

### Black Screen / Video Not Playing

**Cause:** The most common cause is an HTTPS certificate error or the browser blocking the connection.

**Fix:**
1. Verify you are using the full `https://` URL (not `http://`).
2. Check that Tailscale Funnel is active:
   ```powershell
   tailscale funnel status
   ```
   If it shows `off` or an error, re-run:
   ```powershell
   tailscale funnel 443
   ```
3. In Safari on iPad, try force-closing the app and reopening.
4. Check that your PC's Tailscale connection is healthy (green icon in system tray).

### No Audio

**Cause:** iOS autoplay policy — audio requires a user gesture before it can start.

**Fix:** Tap anywhere on the stream canvas after the video starts. If this does not work:
1. Check that the remote PC is not muted.
2. Open Sunshine dashboard (`https://localhost:47990`) → **Configuration** → **Audio** → verify the audio sink is set to the correct output device.
3. Check Windows sound settings — ensure the correct playback device is selected.

### Keyboard Not Working / Keys Not Forwarded

**Cause 1:** Keyboard Lock experimental feature is causing conflicts.  
**Fix:** Disable Keyboard Lock in app settings, use on-screen modifier keys.

**Cause 2:** The stream canvas does not have focus.  
**Fix:** Tap the canvas once to give it focus.

**Cause 3:** iPadOS is intercepting system shortcuts.  
**Fix:** Some shortcuts (e.g., `Cmd+H`) cannot be forwarded. Use the on-screen Win key button for those.

### Pointer Lock Not Working

**Cause:** The page is loaded over HTTP, or the browser denied the pointer lock request.

**Fix:**
1. Confirm the URL starts with `https://`.
2. Tap the canvas, then immediately tap **Allow** in the browser prompt (it disappears after a few seconds).
3. In Safari Settings → [your site] → confirm no special permissions are blocked.

### "VideoDecoder not supported" Error

**Cause:** The browser does not support the WebCodecs API, which is required for hardware-accelerated video decode.

**Fix:**
1. Update to iPadOS 17.0 or later.
2. Update Safari to version 17 or later (Settings → General → Software Update).
3. If the device is pre-A9X, the HEVC codec may not be supported — the client should automatically fall back to H.264. If it does not, file a bug report.
4. If you are on a Mac and testing in Chrome, WebCodecs hardware acceleration for HEVC may require Chrome 116+ on macOS 13+.

### Tailscale Not Connecting / App Shows "Offline"

**Cause:** Tailscale is not authenticated or the Funnel is not active.

**Fix:**
1. Check the Tailscale system tray icon on the PC — it should be green.
2. Run `tailscale status` in PowerShell and verify the device is listed.
3. Re-authenticate: open Tailscale → **Re-authenticate**.
4. Re-run the funnel setup script:
   ```powershell
   powershell -File "C:\Program Files\RemoteDesktop\scripts\funnel-setup.ps1"
   ```

### Stream Looks Blurry / Low Quality

**Cause:** Bitrate is too low for the current resolution, or the codec is falling back to H.264.

**Fix:**
1. Increase the bitrate in Sunshine dashboard.
2. If on H.264 fallback, check if your iPad supports HEVC (A9X+). If it does, verify the server is offering HEVC — check server logs.
3. If on a cellular/slow connection, lower the resolution to 720p instead.

### Audio and Video Out of Sync

**Cause:** Network jitter causing audio/video desynchronisation.

**Fix:**
1. Switch to a 5 GHz Wi-Fi network.
2. Disconnect and reconnect to reset the stream buffers.
3. Check that no other devices are consuming bandwidth heavily on the same network.
