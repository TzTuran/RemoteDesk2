# Remote Desktop Solution — Stream your Windows PC to iPad via WebRTC

[![Build Status](https://github.com/your-org/remote-desktop-solution/actions/workflows/build-installer.yml/badge.svg)](https://github.com/your-org/remote-desktop-solution/actions/workflows/build-installer.yml)
[![Security Audit](https://github.com/your-org/remote-desktop-solution/actions/workflows/security-audit.yml/badge.svg)](https://github.com/your-org/remote-desktop-solution/actions/workflows/security-audit.yml)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows-0078d4.svg?logo=windows)](https://github.com/your-org/remote-desktop-solution/releases/latest)
[![Latest Release](https://img.shields.io/github/v/release/your-org/remote-desktop-solution?label=Latest%20Release)](https://github.com/your-org/remote-desktop-solution/releases/latest)

Hardware-accelerated, low-latency Windows desktop streaming to an iPad browser using WebRTC — no app store required.

---

## Architecture

| Component     | Technology                | Purpose                                            |
|---------------|---------------------------|----------------------------------------------------|
| Sunshine      | C++, NVENC / AMF / QSV    | Screen capture + WebRTC streaming engine           |
| Moonlight-Web | Rust + TypeScript         | Browser-based WebRTC client (Safari / iPad PWA)    |
| Tailscale     | WireGuard mesh VPN        | Secure end-to-end networking + automatic HTTPS     |
| coturn        | Docker (optional)         | TURN relay for NAT traversal on restrictive networks |

```
Windows PC ──[Sunshine capture]──► [Moonlight Web Server]
                                          │
                                    Tailscale Funnel
                                     (HTTPS / WireGuard)
                                          │
                                    iPad Safari 17+
                                   (WebRTC, PWA, HEVC)
```

---

## Quick Start

1. **Download** the latest installer from [Releases](https://github.com/your-org/remote-desktop-solution/releases/latest).
2. **Run** `RemoteDesktopSetup-vX.X.X.exe` as Administrator.
3. **Follow the wizard** — create a login, authenticate with Tailscale, GPU is auto-detected.
4. **Note your URL** — the wizard shows your Tailscale HTTPS URL (e.g., `https://my-pc.tail12345.ts.net`).
5. **Open Safari on iPad**, navigate to the URL, log in, and optionally **Add to Home Screen** for a full-screen PWA experience.

---

## Features

- **1080p60 streaming** with hardware-accelerated encoding (NVENC, AMF, QSV)
- **HEVC (H.265)** codec for high-quality video at lower bitrates — automatic H.264 fallback for older iPads
- **<50ms latency on LAN** with direct Tailscale peer-to-peer connection
- **iPad Safari PWA** — install to Home Screen, full-screen no-chrome experience
- **Magic Keyboard + Trackpad** support with Pointer Lock for native mouse feel
- **Zero port forwarding** — Tailscale Funnel handles HTTPS termination and routing
- **Automatic TURN relay** via coturn for restrictive networks and cellular connections
- **One-click installer** — sets up Sunshine, Moonlight Web, Tailscale, and coturn in one step

---

## System Requirements

### Windows PC (Host)

| Requirement | Minimum |
|-------------|---------|
| OS | Windows 10 1903+ or Windows 11 |
| GPU | NVIDIA GTX 1000 / AMD RX 500 / Intel 6th-gen (for hardware encode) |
| RAM | 8 GB |
| Network | 100 Mbps Ethernet (recommended) or 5 GHz Wi-Fi |

### iPad (Client)

| Requirement | Minimum |
|-------------|---------|
| Model | iPad mini 6, iPad Air 3rd gen, or iPad Pro (any) |
| iPadOS | 17.0+ |
| Browser | Safari 17+ |

---

## Documentation

| Document | Description |
|----------|-------------|
| [User Guide](docs/USER_GUIDE.md) | Complete installation and usage guide |
| [iPad Setup](docs/IPAD_SETUP.md) | iPad-specific setup, hardware compatibility, PWA |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Diagnose and fix common issues |

---

## Building from Source

### Prerequisites

- [Rust](https://rustup.rs/) (stable, 1.77+)
- [Node.js](https://nodejs.org/) 20+
- [NSIS](https://nsis.sourceforge.io/) 3.x (Windows, for installer)

### Build Steps

```bash
# 1. Build the frontend
cd moonlight-web/web
npm ci
npm run build

# 2. Copy static files for the server
cp -r dist/ ../server/static/

# 3. Build the Rust server
cd ../server
cargo build --release

# 4. Build the installer (Windows only)
cd ../../installer
powershell -File build.ps1
```

The resulting installer will be in `installer/Output/`.

### CI/CD

This project uses GitHub Actions for automated builds and security audits:

- **[build-installer.yml](.github/workflows/build-installer.yml):** Builds the frontend, server, and NSIS installer. Creates a GitHub Release on version tags.
- **[security-audit.yml](.github/workflows/security-audit.yml):** Runs `cargo audit`, `npm audit`, and CodeQL analysis weekly and on every push to `main`.

---

## Contributing

Contributions are welcome. Please:

1. Fork the repository and create a feature branch.
2. Follow existing code style (run `cargo fmt` and `npm run lint`).
3. Add or update tests for new functionality.
4. Open a Pull Request against `main` with a clear description.

For major changes, open an issue first to discuss the approach.

### Reporting Security Issues

Do not open public issues for security vulnerabilities. Email `security@your-org.example` or use [GitHub's private security advisory](https://github.com/your-org/remote-desktop-solution/security/advisories/new) feature.

---

## License

This project is licensed under the **GNU General Public License v3.0**. See [LICENSE](LICENSE) for the full text.

Components used by this project:
- [Sunshine](https://github.com/LizardByte/Sunshine) — GPL-3.0
- [Moonlight Web Stream](https://github.com/MrCreativ3001/moonlight-web-stream) — GPL-3.0
- [Tailscale](https://github.com/tailscale/tailscale) — BSD-3-Clause
- [coturn](https://github.com/coturn/coturn) — BSD

---

## Acknowledgments

This project builds on the outstanding work of:

- **[LizardByte/Sunshine](https://github.com/LizardByte/Sunshine)** — the open-source Moonlight host application that does the heavy lifting of GPU-accelerated capture and WebRTC streaming.
- **[MrCreativ3001/moonlight-web-stream](https://github.com/MrCreativ3001/moonlight-web-stream)** — the browser-based Moonlight client that made iPad streaming possible.
- The **Tailscale** team for building a VPN that simply works.
- The **Moonlight** and **GameStream** communities for years of protocol documentation and tooling.
