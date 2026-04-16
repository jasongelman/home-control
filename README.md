# Home Control

A whole-home smart home system with native iOS and web clients on top of a Node.js integration server. Lutron HomeWorks lighting and shades are the core; everything else — thermostats, alarm, garage, laundry, dishwasher, heat pump, speakers, cameras — rides alongside in the same dashboard.

## Repo layout

```
home-control/
├── ios/          # Native SwiftUI iPhone app + home-screen widget
├── web/          # React + Vite browser app
├── server/       # Node.js/TypeScript bridge + REST + WebSocket
├── docs/         # Specs, plans, design notes
└── workers/      # Small background scripts
```

The **server** holds all cloud credentials, talks to each vendor API, and exposes a single REST + WebSocket surface the **web** client binds to. The **iOS** app talks to the server for Lutron (LEAP/mTLS via the server) and for anything the server brokers, but also holds its own direct clients for integrations where going through the server would add a pointless hop (MyQ, SmartHQ, Resideo Total Connect, Sonos local). See `CLAUDE.md` for the exact feature-parity rules.

```
iPhone App  ──┐      ┌──▶  Lutron Processor  (LEAP over mTLS)
              ├──▶  server  ──▶  Home Connect / myUplink / Ecobee / ...
Web Browser ──┘      └──▶  Anthropic API  (chat assistant)

iPhone App ──▶ rs.alarmnet.com / MyQ / SmartHQ / Sonos LAN (direct)
```

## Integrations

| Integration | Protocol | Server | iOS direct | Web |
|---|---|:-:|:-:|:-:|
| Lutron HomeWorks QSX (lights, shades, keypads) | LEAP / mTLS | ✅ | — | ✅ |
| Ecobee (thermostats + remote sensors) | Cloud REST (PIN OAuth) + HomeKit fallback | ✅ | ✅ (HomeKit) | ✅ |
| Resideo Total Connect 2.0 (alarm) | SOAP (direct) | ✅ | ✅ | ✅ |
| Chamberlain / LiftMaster MyQ (garage) | Reverse-engineered cloud | — | ✅ | ✅ (via server) |
| Bosch Home Connect (dishwasher) | OAuth 2.0 | ✅ | — | ✅ |
| GE SmartHQ (washer/dryer) | OAuth 2.0 | ✅ | ✅ | ✅ |
| Dandelion / myUplink (geothermal) | OAuth 2.0 | ✅ | — | ✅ |
| Sonos | S2 Cloud OAuth + local UPnP | ✅ | ✅ | ✅ |
| HomeKit scenes | HomeKit framework | — | ✅ | — |
| RTSP cameras | RTSP / HLS | — | ✅ | ✅ |
| Anthropic Claude (chat assistant) | REST | ✅ | — | ✅ |

iOS parity with the web client is a hard rule — see the "Keep iOS and web at feature parity" section of `CLAUDE.md`.

---

## iOS App (`ios/`)

**Tech:** SwiftUI, `@Observable`, LEAP over mTLS, HomeKit, WidgetKit, App Intents, BackgroundTasks, AVFoundation, Speech

**Location:** `ios/LutronHome/LutronHome.xcodeproj` (scheme `LutronHome`, bundle id `com.jasongelman.LutronHome`)

### Features
- Unified dashboard: top-row status grid covering thermostats, alarm, dishwasher, washer/dryer, garage, heat pump, Sonos, lights
- Per-room light control with drag-to-dim pills (brightness fill behind device name)
- Shade/drape control with open/close pills and position fill
- Room-grouped "Lights On" overview with room headers
- "For You" adaptive suggestions based on usage patterns
- Ecobee thermostat control with per-room remote sensors
- Resideo Total Connect alarm (arm/disarm, zone faults) — direct, no server required
- Garage door control (MyQ) — direct
- Bosch dishwasher status (Home Connect OAuth)
- GE washer & dryer status (SmartHQ) — direct
- Dandelion geothermal heat pump status (myUplink)
- Sonos control — S2 Cloud OAuth primary, local UPnP fallback
- HomeKit scene triggering
- RTSP camera stream viewer
- Claude-powered chat assistant (routed through the server)
- Voice commands (Speech framework + App Intents / Siri)
- Home-screen **widget** (small + medium) with background refresh via `BGAppRefreshTask` to keep cloud-backed tiles fresh even when the app isn't foreground
- Push-style local notifications for alarm + appliance events
- Time-aware dark/warm theming driven by sunrise/sunset

### Building
```bash
cd ios/LutronHome
xcodebuild -project LutronHome.xcodeproj -scheme LutronHome \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```
The `iPhone 17` simulator is the current default target. `iPhone 16` is no longer in the default simulator set on this repo's build machine.

### Configuration
On first launch, open **Settings** and enter the processor IP of the machine running the server. Each third-party integration has its own auth flow in Settings (OAuth PIN flows for Ecobee, OAuth redirect flows for Home Connect / myUplink / Sonos, username+password for MyQ / SmartHQ / Total Connect). Credentials are stored in Keychain; non-sensitive state in `UserDefaults`. The web client never receives raw credentials — anything the server holds is held only server-side.

### Key source files

| File | Purpose |
|------|---------|
| `LutronHomeApp.swift` | App entry point, env injection, BG task registration, widget sync |
| `ContentView.swift` | Home/Lights/Shades/Appliances tabs + status-glance grid |
| `LutronStore.swift` | WebSocket client + device state + LEAP commands via server |
| `AppGroupManager.swift` | Shared snapshot layer for the widget |
| `WidgetBackgroundRefresh.swift` | BGAppRefreshTask handler — polls cloud integrations |
| `EcobeeManager.swift` | Ecobee PIN OAuth + polling + HomeKit fallback |
| `TotalConnectManager.swift` | Direct Resideo Total Connect 2.0 client |
| `SonosManager.swift` / `SonosCloudClient.swift` / `SonosLocalClient.swift` | Sonos (cloud + LAN) |
| `MyQManager.swift` | Chamberlain MyQ client |
| `SmartHQManager.swift` | GE SmartHQ client |
| `HomeConnectManager.swift` | Bosch Home Connect OAuth |
| `MyUplinkManager.swift` | Dandelion geothermal OAuth |
| `HomeKitManager.swift` | HomeKit scene triggering |
| `ChatService.swift` / `ChatView.swift` | Server-brokered Claude chat |
| `CameraStreamView.swift` | RTSP viewer |
| `NotificationManager.swift` | Local notifications |
| `UsageTracker.swift` + `RecommendationEngine.swift` | "For You" suggestions |
| `SettingsView.swift` | All integration setup flows |
| `Intents/` + `SuggestedAction.swift` | App Intents / Siri |

`LutronHomeWidget/` (extension): `SmallWidgetView.swift` (single status line), `MediumWidgetView.swift` (4×2 status grid mirroring the dashboard), `WidgetTimelineProvider.swift`.

---

## Web App (`web/`)

**Tech:** React 19, TypeScript, Vite, MUI

### Features
- Same control surface as iOS (pill-style light + shade, room grid, adaptive For You)
- Ecobee thermostat + sensor cards
- Alarm arm/disarm + zone list
- Garage, dishwasher, washer/dryer, heat pump cards
- Sonos control
- Scene CRUD + scheduling
- Chat panel (Claude)
- Setup / integration config dialogs
- Responsive (mobile + desktop)

### Running
```bash
# From project root (npm workspaces)
npm install
cd web && npm run dev    # http://localhost:5173
cd web && npm run build  # production build (also type-checks)
```

### Key source files

| File | Purpose |
|------|---------|
| `src/App.tsx` | Root + WebSocket setup |
| `src/components/Dashboard.tsx` | Home view: For You, Quick Actions, Lights On, Rooms grid |
| `src/components/RoomDetail.tsx` | Per-room light/shade/scene controls |
| `src/components/AlarmControl.tsx` | Resideo Total Connect panel |
| `src/components/AppliancesSection.tsx` | Dishwasher / laundry / heat pump |
| `src/components/ChatPanel.tsx` | Claude chat |
| `src/components/SceneCard.tsx` / `SceneEditor.tsx` | Scenes |
| `src/components/SettingsDialog.tsx` | All integration setup |
| `src/components/setup/` | First-run flows |
| `src/components/devices/` | Light, shade, garage, etc. controls |
| `src/context/LutronContext.tsx` | Global state + WebSocket events |
| `src/hooks/useWebSocket.ts` | WebSocket connection + message handling |
| `src/hooks/useAdaptiveDashboard.ts` | For You suggestions |
| `src/hooks/usePatternDetector.ts` | Usage pattern detection |
| `src/hooks/useScenes.ts` | Scene CRUD |

---

## Server (`server/`)

**Tech:** Node.js, TypeScript (strict), `ws`, `@seald-io/nedb`, Express

Brokers every cloud integration, maintains Lutron LEAP connection, and exposes a WebSocket + REST API. Holds all credentials (gitignored — see `CLAUDE.md` "Never commit secrets").

### Running
```bash
cd server
npm install
npm run dev     # ts-node watch mode
npm run build   # compile to dist/
npm start       # run compiled output
```

Listens on **port 3001** (WebSocket + REST).

### Source layout
```
server/src/
├── index.ts                  # Entry — wires integrations, WS, REST together
├── config.ts                 # Persistent config (NeDB + config.json)
├── api/
│   ├── routes.ts             # Express REST routes
│   └── websocket.ts          # WS message handling
├── lutron/                   # LEAP/mTLS client + connection state machine
├── homeconnect/              # Bosch dishwasher OAuth
├── myq/                      # Chamberlain/LiftMaster garage
├── myuplink/                 # Dandelion geothermal OAuth
├── smarthq/                  # GE washer/dryer
├── totalconnect/             # Resideo Total Connect 2.0 SOAP
├── state/                    # Device registry + state sync
├── automation/               # Scene execution + pattern detection
├── scripts/                  # One-off maintenance scripts
└── utils/
```

Each integration follows the same shape: a stateless `*Client` (HTTP/SOAP wrapper) + a `*Manager`/`*Poller` (EventEmitter with token refresh, polling, and event emission). `totalconnect/` is the canonical reference when adding a new one.

### REST API (selected)

| Endpoint | Method | Description |
|---|---|---|
| `/api/status` | GET | Connection status |
| `/api/config` | GET/PUT | Processor IP and app config |
| `/api/scenes` | GET/POST | Scene CRUD |
| `/api/scenes/:id/activate` | POST | Run a scene |
| `/api/myq/...` | | Garage door config + control |
| `/api/homeconnect/...` | | Dishwasher OAuth + state |
| `/api/smarthq/...` | | Washer/dryer |
| `/api/myuplink/...` | | Heat pump |
| `/api/ecobee/...` | | Thermostat PIN flow + control |
| `/api/totalconnect/...` | | Alarm arm/disarm |
| `/api/sonos/...` | | Speakers + OAuth redirect |
| `/api/chat` | POST | Server-brokered Claude chat |

### WebSocket protocol

Server pushes real-time state changes to all connected clients.

**Server → Client:**
```jsonc
{ "type": "fullState", "devices": [...], "connected": true, "doors": [...], ... }
{ "type": "deviceState", "integrationId": 3, "level": 75 }
{ "type": "garageState", "serial": "...", "state": "open" }
{ "type": "thermostatState", ... }
{ "type": "alarmState", ... }
```

**Client → Server:**
```jsonc
{ "type": "setLevel", "integrationId": 3, "level": 75, "fadeTime": 1 }
{ "type": "garageAction", "serial": "...", "action": "open" }
{ "type": "thermostatAction", ... }
{ "type": "alarmAction", ... }
```

---

## Lutron LEAP setup

The server connects to the Lutron processor over mutual TLS. Generate the client cert pair once:

1. Put the processor into pairing mode (hold the pairing button).
2. Run the pairing script: `cd server && npx ts-node src/lutron/LEAPPairing.ts <PROCESSOR_IP>`
3. Produces `lutron_client.p12` (used by server) and an equivalent blob the iOS app embeds.

The processor IP is stored in server config (settable via `PUT /api/config` or the web Settings dialog).

---

## Third-party integration setup

Short summary — full setup lives in each Settings screen.

- **Ecobee** — PIN OAuth. Request PIN in Settings, paste it into ecobee.com/consumerportal, complete exchange.
- **Resideo Total Connect 2.0** — username + password + 4-digit user code. Server and iOS each hold their own copy (two implementations of the same SOAP protocol; iOS can operate without the server running).
- **MyQ** (Chamberlain) — email + password. Uses community-reverse-engineered client constants (see `CLAUDE.md` exception list).
- **Home Connect** — OAuth 2.0. Register at [developer.home-connect.com](https://developer.home-connect.com) with redirect `com.jasongelman.lutronhome://oauth/homeconnect`.
- **SmartHQ** — email + password. Community-reverse-engineered client constants.
- **myUplink** — OAuth 2.0. Register at [dev.myuplink.com](https://dev.myuplink.com) with redirect `com.jasongelman.lutronhome://oauth/myuplink`.
- **Sonos** — S2 Cloud OAuth (register a control integration at [developer.sonos.com](https://developer.sonos.com)), with local UPnP as fallback for LAN-only commands.
- **Anthropic (chat)** — API key in server config; never exposed to clients.

See `server/data/config.example.json` and `.env.example` for the full required-keys list.

---

## Contributing

Read `CLAUDE.md` before touching code. Key rules:

1. **Never commit an un-built merge or rebase** — always run iOS + server + web builds after resolving conflicts.
2. **Reconcile conflicts semantically** — don't "accept both" when one side refactored structure.
3. **Keep iOS and web at feature parity** — any user-facing feature reachable on one must be reachable on the other.
4. **Never commit secrets** — credentials live in gitignored `server/data/config.json` / `.env` or in iOS Keychain, never in tracked files. Narrow exception documented in `CLAUDE.md` for community-reverse-engineered vendor client constants.
5. **Adding a Swift file requires a `project.pbxproj` edit** — three entries (`PBXBuildFile`, `PBXFileReference`, `Sources` build phase). Xcode will silently drop unreferenced files from the build.
