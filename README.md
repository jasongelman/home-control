# Lutron Home

A whole-home smart home controller with native iOS and web interfaces. Controls Lutron lighting and shades via the LEAP protocol, plus integrations for garage doors (MyQ), dishwasher (Bosch Home Connect), washer/dryer (GE SmartHQ), and geothermal heat pump (Dandelion/myUplink).

## Architecture

```
lutron-home/
├── ios/          # Native SwiftUI iPhone app
├── web/          # React browser app
└── server/       # Node.js bridge server (LEAP ↔ WebSocket)
```

The **server** connects directly to the Lutron Caseta/RA2 processor over mTLS (LEAP protocol on port 8081), then exposes a WebSocket + REST API that both the web and iOS apps consume. No cloud services involved for Lutron control.

```
iPhone App  ──┐
              ├──▶  server (Node.js)  ──▶  Lutron Processor (LEAP/mTLS)
Web Browser ──┘         │
                        └──▶  MyQ Cloud API (garage doors)
```

---

## iOS App (`ios/`)

**Tech:** SwiftUI, `@Observable`, LEAP over mTLS (URLSession + custom TLS), HomeKit, AVFoundation

**Location:** `ios/LutronHome/LutronHome.xcodeproj`

### Features
- Live light control with drag-to-dim pills (brightness fill behind device name)
- Shade/drape control with open/close pills and position fill
- Room-grouped "Lights On" overview on the Home tab with room headers
- "For You" adaptive suggestions based on usage patterns
- Garage door control (MyQ — Chamberlain/LiftMaster)
- Bosch dishwasher status (Home Connect OAuth)
- GE washer & dryer status (SmartHQ)
- Dandelion geothermal heat pump status (myUplink OAuth)
- HomeKit scene triggering
- Camera stream viewer
- Time-aware dark/warm color theming

### Building

```bash
cd ios/LutronHome
# Build for simulator
xcodebuild -project LutronHome.xcodeproj -scheme LutronHome \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# Build for device (replace DEVICE_ID)
xcodebuild -project LutronHome.xcodeproj -scheme LutronHome \
  -configuration Debug \
  -destination 'id=DEVICE_ID' build

# Install on device after building
xcrun devicectl device install app \
  --device DEVICE_ID \
  /path/to/DerivedData/.../LutronHome.app
```

### Configuration
The app connects to the server via WebSocket. On first launch, go to **Settings → Processor IP Address** and enter the IP of the machine running the server. Third-party integrations (MyQ, Home Connect, SmartHQ, myUplink) are configured from the Settings screen.

### Key Source Files

| File | Purpose |
|------|---------|
| `ContentView.swift` | All tabs: Home, Lights, Shades, Appliances; DimPill component |
| `LutronStore.swift` | WebSocket client, device state, LEAP commands |
| `LutronHomeApp.swift` | App entry point, environment injection |
| `SettingsView.swift` | Processor IP, all third-party auth flows |
| `MyQManager.swift` | MyQ garage door cloud API |
| `HomeConnectManager.swift` | Bosch dishwasher OAuth integration |
| `SmartHQManager.swift` | GE washer/dryer credential auth |
| `MyUplinkManager.swift` | Dandelion geothermal OAuth integration |
| `HomeKitManager.swift` | HomeKit scene triggering |
| `UsageTracker.swift` | Records device interactions for "For You" suggestions |
| `PersonalizationInsightsView.swift` | Debug view for usage events |
| `LEAPClient.swift` | Direct LEAP protocol client (mTLS) |
| `SunCalculator.swift` | Sunrise/sunset for time-aware theming |

---

## Web App (`web/`)

**Tech:** React 19, TypeScript, Vite, MUI (Material UI)

### Features
- Identical control surface to the iOS app (pill-style light and shade controls)
- Room-grouped "Lights On" section with drag-to-dim pills
- Adaptive "For You" suggestions driven by usage history
- Scene creation and scheduling
- Garage door controls (MyQ)
- Third-party appliance settings (same integrations as iOS)
- Responsive layout (mobile and desktop)

### Running

```bash
# From project root (npm workspaces)
npm install

# Dev server (http://localhost:5173)
cd web && npm run dev

# Production build
cd web && npm run build

# Type-check
cd web && npm run build  # runs tsc -b first
```

### Key Source Files

| File | Purpose |
|------|---------|
| `src/App.tsx` | Root component, WebSocket setup |
| `src/components/Dashboard.tsx` | Home view: For You, Quick Actions, Lights On, Rooms grid |
| `src/components/RoomDetail.tsx` | Per-room light/shade/scene controls |
| `src/components/devices/LightControl.tsx` | Single-line dim pill for lights |
| `src/components/devices/ShadeControl.tsx` | Single-line position pill for shades |
| `src/components/devices/GarageDoorControl.tsx` | MyQ garage door card |
| `src/components/SettingsDialog.tsx` | All settings and third-party auth |
| `src/context/LutronContext.tsx` | Global state, WebSocket events |
| `src/hooks/useWebSocket.ts` | WebSocket connection + message handling |
| `src/hooks/useAdaptiveDashboard.ts` | "For You" suggestions logic |
| `src/hooks/usePatternDetector.ts` | Usage pattern detection |
| `src/hooks/useScenes.ts` | Scene CRUD via REST API |

---

## Server (`server/`)

**Tech:** Node.js, TypeScript, `ws` (WebSocket), `@seald-io/nedb`

Bridges the Lutron LEAP protocol to a WebSocket/REST API consumed by the iOS and web apps.

### Running

```bash
cd server
npm install
npm run dev     # ts-node watch mode
npm run build   # compile to dist/
npm start       # run compiled output
```

The server listens on:
- **Port 3001** — WebSocket (`ws://HOST:3001`) + REST API (`http://HOST:3001/api/`)

### REST API

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/status` | GET | Connection status |
| `/api/config` | GET/PUT | Processor IP and app config |
| `/api/scenes` | GET/POST | Scene CRUD |
| `/api/scenes/:id` | PUT/DELETE | Update/delete scene |
| `/api/scenes/:id/activate` | POST | Run a scene |
| `/api/myq/status` | GET | MyQ connection + door states |
| `/api/myq/config` | GET/PUT | MyQ credentials |
| `/api/myq/doors/:serial/action` | PUT | Open/close a garage door |

### WebSocket Protocol

The server pushes real-time state changes to all connected clients.

**Server → Client messages:**
```jsonc
// Full state snapshot on connect
{ "type": "fullState", "devices": [...], "connected": true, "doors": [...], "myqConnected": true }

// Single device level/state change
{ "type": "deviceState", "integrationId": 3, "level": 75 }

// Garage door state change
{ "type": "garageState", "serial": "...", "state": "open" }
```

**Client → Server messages:**
```jsonc
// Set light/shade level
{ "type": "setLevel", "integrationId": 3, "level": 75, "fadeTime": 1 }

// Trigger garage door
{ "type": "garageAction", "serial": "...", "action": "open" }
```

### Key Source Files

| File | Purpose |
|------|---------|
| `src/index.ts` | Entry point, wires everything together |
| `src/lutron/LEAPConnection.ts` | mTLS LEAP protocol client |
| `src/lutron/LEAPClient.ts` | High-level device commands |
| `src/lutron/LutronConnection.ts` | Connection state machine |
| `src/lutron/types.ts` | Shared type definitions |
| `src/myq/MyQClient.ts` | Chamberlain/LiftMaster cloud API |
| `src/myq/MyQPoller.ts` | Polling + event emission for door state |
| `src/api/routes.ts` | Express REST routes |
| `src/api/websocket.ts` | WebSocket message handling |
| `src/state/` | State synchronization, device registry |
| `src/automation/` | Scene execution, pattern detection |
| `src/config.ts` | Config persistence (NeDB) |

---

## Lutron LEAP Setup

The server connects to the Lutron processor using mutual TLS (mTLS). You need a client certificate pair:

1. Put the Lutron processor into pairing mode (hold the pairing button)
2. Run the pairing script: `cd server && npx ts-node src/lutron/LEAPPairing.ts <PROCESSOR_IP>`
3. This generates `lutron_client.p12` (used by the server) and an equivalent for the iOS app

The processor IP is stored in the server config and can be updated via `PUT /api/config`.

---

## Third-Party Integrations

### MyQ (Chamberlain/LiftMaster Garage)
Uses the reverse-engineered MyQ cloud API. Configure email/password in Settings. Note: Chamberlain has restricted third-party access — this may break if they change their API.

### Home Connect (Bosch Dishwasher)
OAuth 2.0 integration. Register at [developer.home-connect.com](https://developer.home-connect.com), create an application, and set the redirect URI to `com.jasongelman.lutronhome://oauth/homeconnect`. Enter the client ID and secret in Settings.

### GE SmartHQ (Washer & Dryer)
Uses SmartHQ account credentials (same as the SmartHQ app). Configure email/password in Settings.

### myUplink (Dandelion Geothermal)
OAuth 2.0 integration. Register at [dev.myuplink.com](https://dev.myuplink.com), set redirect URI to `com.jasongelman.lutronhome://oauth/myuplink`. Enter client ID and secret in Settings.
