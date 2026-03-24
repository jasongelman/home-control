# LutronHome

A native iOS smart home dashboard that unifies **Lutron HomeWorks QSX** lighting and shade control with **HomeKit cameras**, **Bosch Home Connect** appliances, and **NIBE myUplink** heat pump monitoring — all in a single app.

Built entirely in **SwiftUI** with direct device communication (no cloud relay for Lutron), the app connects to your processor over your local network or via VPN when away from home.

---

## Features

### Lighting & Shade Control
- **Direct LEAP protocol** connection to Lutron HomeWorks QSX processor over mTLS (port 8081)
- Per-room brightness sliders and shade position controls
- Quick actions for common scenes (Evening, Goodnight, Movie, etc.)
- Floor-level controls — turn off all lights on a floor with one tap
- Real-time device state updates via LEAP subscriptions
- Automatic reconnect with exponential backoff

### HomeKit Camera Integration
- **Multi-camera live streaming** with auto-rotation between cameras
- LIVE indicator with camera name overlay
- **Two-way audio** — talk through cameras with mic toggle and volume control
- **Snapshot capture** with on-disk caching (camera images persist across launches)
- Full-screen camera detail view with playback controls
- Camera selector strip with cached thumbnail previews

### Bosch Home Connect
- **Dishwasher monitoring** — supports multiple appliances per household
- Real-time status: operation state, door state, program progress, time remaining
- **Server-Sent Events (SSE)** for instant status updates
- OAuth 2.0 authentication with token refresh

### NIBE Heat Pump (myUplink)
- **Geothermal heat pump telemetry** — outdoor, supply, return, brine, and hot water temperatures
- Compressor frequency and current power draw (kW)
- Operating mode display (Heating / Cooling / Hot Water)
- Smart home mode control (Away / Home / Default)
- OAuth 2.0 authentication with automatic token refresh

### Garage Door
- Open/close control with obstruction detection
- Current and target state monitoring via HomeKit

### Time-Aware UI
- **Sunrise/sunset calculation** using NOAA solar equations (no API dependency)
- Dynamic greeting and app theme that shifts throughout the day
- Contextual quick actions — "Open Shades" in the morning, "Close Shades" at sunset, "Goodnight" at night
- Accent colors adapt: warm orange during the day, cool indigo at dawn, deep blue at night

### Network Awareness
- Detects WiFi vs. cellular connectivity
- Shows contextual banner when off home network with **"Open Tailscale"** VPN deep-link
- Instant reconnect when returning from VPN app

---

## Architecture

```
LutronHome/
├── LutronHomeApp.swift          # App entry point, environment injection
├── ContentView.swift            # Tab bar, dashboard, room cards, quick actions
├── RoomDetailView.swift         # Per-room device controls
├── SettingsView.swift           # Connection config, OAuth linking, about
├── CameraStreamView.swift       # Camera carousel, full-screen detail, two-way audio
├── LutronStore.swift            # LEAP connection, device state, network monitoring
├── LEAPClient.swift             # WebSocket LEAP protocol client (mTLS)
├── HomeKitManager.swift         # Cameras, garage doors, snapshots, streaming
├── HomeConnectManager.swift     # Bosch OAuth + REST/SSE dishwasher integration
├── MyUplinkManager.swift        # NIBE OAuth + REST heat pump telemetry
├── SunCalculator.swift          # NOAA sunrise/sunset, time periods, themes
├── Models.swift                 # DeviceState, DeviceType, Floor, Scene models
└── KeychainHelper.swift         # Secure credential storage
```

All managers use Swift's `@Observable` macro and are injected as SwiftUI environment values from the app root.

### Communication Protocols

| Integration | Protocol | Auth | Real-time |
|---|---|---|---|
| **Lutron QSX** | LEAP over WebSocket | mTLS (client certificate) | LEAP subscriptions |
| **HomeKit** | Apple HomeKit framework | HomeKit pairing | Delegate callbacks |
| **Bosch Home Connect** | REST + SSE | OAuth 2.0 | Server-Sent Events |
| **NIBE myUplink** | REST | OAuth 2.0 | 60s polling |

---

## Setup

### Prerequisites
- Xcode 16+
- iOS 17+ device
- Lutron HomeWorks QSX processor on your local network
- (Optional) HomeKit-enabled cameras and garage door
- (Optional) Bosch Home Connect account + OAuth credentials
- (Optional) NIBE myUplink account + OAuth credentials

### Build & Deploy

```bash
# Build for device
xcodebuild -project LutronHome.xcodeproj \
  -scheme LutronHome \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  build

# Install to connected device
xcrun devicectl device install app \
  --device <DEVICE_UDID> \
  path/to/LutronHome.app
```

### Configuration

On first launch, go to **Settings** and configure:

1. **Processor IP** — Enter your Lutron processor's local IP address (default: `192.168.1.191`)
2. **Home Connect** — Enter your Bosch OAuth Client ID and Secret, then tap "Link Account"
3. **myUplink** — Enter your NIBE OAuth Client ID and Secret, then tap "Link Account"

HomeKit cameras and garage doors are discovered automatically.

### OAuth Redirect URIs

When registering OAuth apps with Bosch or NIBE, use this redirect URI:

```
com.jasongelman.lutronhome://oauth-callback
```

### Remote Access

When away from your home network, use [Tailscale](https://tailscale.com/) (or any VPN) to reach your processor. The app detects when you're off-network and shows a banner with a direct link to open Tailscale.

---

## Technology

- **SwiftUI** — Declarative UI with `@Observable` state management
- **HomeKit** — `HMCameraStreamControl`, `HMCameraSnapshotControl`, garage door accessories
- **Network.framework** — `NWPathMonitor` for connectivity detection
- **Security.framework** — Keychain storage for credentials and tokens
- **ASWebAuthenticationSession** — OAuth 2.0 flows for Home Connect and myUplink
- **NOAA Solar Equations** — Sunrise/sunset without external API calls

---

## License

Private project. Not for redistribution.
