# Sonos Integration Design

## Context

The home has 3 Sonos speakers across 2 rooms:
- **Family Room:** Sonos Beam (soundbar)
- **Kitchen:** Sonos Amp powering 2 speakers (treated as a single player by Sonos)

No Sonos integration exists in the app. The server is not always running (runs on a local Mac, not deployed), so this is an **iOS-only integration** — same pattern as the Ecobee/HomeKit thermostat integration. Server/web support can be added later when the server is deployed.

## Architecture

```
iOS App
├── SonosLocalClient (UPnP/SOAP — primary)
│   ├── SSDP discovery → find speakers on LAN
│   ├── SOAP transport → play/pause/skip/volume/seek
│   ├── SOAP queue → view/remove/clear queue
│   ├── SOAP grouping → group/ungroup rooms
│   └── UPnP eventing → real-time state updates via local HTTP listener
│
└── SonosCloudClient (REST + OAuth — optional, for browsing)
    ├── OAuth2 authorization code flow
    ├── Browse favorites
    ├── Browse playlists
    └── Start playback of favorite/playlist on a speaker
```

`SonosManager` is the top-level `@Observable` class that owns both clients and publishes unified state. The local client is the primary source for real-time playback state. The cloud client is used only for browsing and starting new content.

## Data Model

### SonosPlayer
| Field | Type | Source |
|-------|------|--------|
| id | String | UPnP device UUID |
| name | String | Room name from device description XML |
| isCoordinator | Bool | Whether this player is the group coordinator |
| groupId | String | Group identifier from ZoneGroupTopology |
| groupMembers | [String] | IDs of other players in the group |
| state | PlaybackState | playing, paused, stopped, transitioning |
| currentTrack | SonosTrack? | Now-playing info |
| volume | Int (0-100) | Current volume level |
| isMuted | Bool | Mute state |
| shuffle | Bool | Shuffle on/off |
| repeatMode | RepeatMode | off, all, one |

### SonosTrack
| Field | Type |
|-------|------|
| title | String |
| artist | String |
| album | String |
| albumArtURL | URL? |
| duration | TimeInterval |
| position | TimeInterval |

### SonosFavorite
| Field | Type |
|-------|------|
| id | String |
| name | String |
| imageURL | URL? |
| type | String (playlist, station, album, etc.) |

### Enums
```swift
enum PlaybackState: String, Codable {
    case playing, paused, stopped, transitioning
}

enum RepeatMode: String, Codable {
    case off, all, one
}
```

## Discovery & Connection

### SSDP Discovery
- Send `M-SEARCH` multicast to `239.255.255.250:1900` for `urn:schemas-upnp-org:device:ZonePlayer:1`
- Parse responses to get each speaker's description URL (e.g., `http://192.168.1.x:1400/xml/device_description.xml`)
- Fetch device description XML to extract: room name, model name, model number, UUID
- Re-run discovery on app foreground

### UPnP Event Subscriptions
- Subscribe to `AVTransport` service → now-playing, playback state changes
- Subscribe to `RenderingControl` service → volume, mute changes
- Subscribe to `ZoneGroupTopology` service → group membership changes
- Subscriptions use `SUBSCRIBE` HTTP method with a callback URL pointing to a lightweight HTTP server running in the app
- Subscriptions expire (typically 1800s / 30 min) — renew before expiry
- Events are XML-encoded, pushed via HTTP `NOTIFY` to the callback

### Local HTTP Listener
The app runs a minimal HTTP server (e.g., on a random high port) to receive UPnP event notifications. This listener:
- Starts on `resume()` (app foreground)
- Stops on `pause()` (app background) — lets subscriptions expire naturally
- Parses incoming `NOTIFY` requests and updates published state

### State Refresh
- On discovery: poll each speaker once for full state via SOAP (`GetTransportInfo`, `GetPositionInfo`, `GetVolume`, `GetMute`)
- After initial poll: rely on UPnP events for real-time updates
- Track position: poll `GetPositionInfo` every 5s while a track is playing (UPnP does not push position continuously)

### Topology Cache
- Persist speaker names, IDs, and IP addresses to `Documents/sonos-topology.json`
- Load on init so UI has data immediately before discovery completes
- Rewrite when topology changes

## Controls

### Transport (local SOAP → AVTransport service)
- `play(playerId)` — `Play` action, speed=1
- `pause(playerId)` — `Pause` action
- `stop(playerId)` — `Stop` action
- `next(playerId)` — `Next` action
- `previous(playerId)` — `Previous` action
- `seek(playerId, position)` — `Seek` action with `REL_TIME` target
- All transport commands target the group coordinator

### Volume (local SOAP → RenderingControl service)
- `setVolume(playerId, level)` — `SetVolume` (0-100), per-speaker
- `setMute(playerId, muted)` — `SetMute`, per-speaker
- Volume is per-speaker even within a group

### Queue (local SOAP → AVTransport + ContentDirectory)
- `getQueue(playerId)` — ContentDirectory `Browse` on object ID `Q:0`
- `removeFromQueue(playerId, index)` — AVTransport `RemoveTrackFromQueue`
- `clearQueue(playerId)` — AVTransport `RemoveAllTracksFromQueue`

### Grouping (local SOAP → AVTransport)
- `groupPlayers(coordinatorId, memberIds)` — on each member, `SetAVTransportURI` with URI `x-rincon:<coordinatorUUID>`
- `ungroupPlayer(playerId)` — `BecomeCoordinatorOfStandaloneGroup`

### Browse & Play (cloud REST — requires OAuth)
- `getFavorites()` — `GET /v1/households/{householdId}/favorites`
- `getPlaylists()` — `GET /v1/households/{householdId}/playlists`
- `playFavorite(groupId, favoriteId)` — `POST /v1/groups/{groupId}/favorites` with `favoriteId`, `playOnCompletion: true`
- `playPlaylist(groupId, playlistId)` — `POST /v1/groups/{groupId}/playlists` with similar body
- `getHouseholds()` — `GET /v1/households` (needed once after OAuth to get householdId)

### OAuth Flow (cloud)
1. User taps "Link Sonos" in Settings
2. Opens `https://api.sonos.com/login/v3/oauth?client_id=...&response_type=code&redirect_uri=...&scope=playback-control-all&state=...` in `ASWebAuthenticationSession`
3. User logs in, authorizes the app
4. Redirect to `com.jasongelman.lutronhome://oauth/sonos?code=...`
5. Exchange authorization code for access + refresh tokens via `POST https://api.sonos.com/login/v3/oauth/access`
6. Store tokens in Keychain
7. Access tokens expire after 24 hours; refresh automatically before expiry

## iOS Implementation

### Files
- `SonosModels.swift` — SonosPlayer, SonosTrack, SonosFavorite, PlaybackState, RepeatMode
- `SonosLocalClient.swift` — SSDP discovery, SOAP commands, UPnP event listener (local HTTP server)
- `SonosCloudClient.swift` — OAuth flow, REST favorites/playlists/playback
- `SonosManager.swift` — @Observable, owns local + cloud clients, publishes unified state

### SonosManager
```swift
@Observable
class SonosManager: @unchecked Sendable {
    var players: [SonosPlayer] = []
    var favorites: [SonosFavorite] = []
    var playlists: [SonosFavorite] = []
    var isCloudLinked: Bool { cloudAccessToken != nil }
    var isLoading = false
    var errorMessage: String?

    func resume()       // start discovery, subscribe to events, start position polling
    func suspendLocal()  // stop HTTP listener, let subscriptions expire

    // Transport
    func play(playerId: String) async throws
    func pausePlayback(playerId: String) async throws
    func next(playerId: String) async throws
    func previous(playerId: String) async throws
    func seek(playerId: String, position: TimeInterval) async throws

    // Volume
    func setVolume(playerId: String, level: Int) async throws
    func setMute(playerId: String, muted: Bool) async throws

    // Queue
    func getQueue(playerId: String) async throws -> [SonosTrack]
    func removeFromQueue(playerId: String, index: Int) async throws
    func clearQueue(playerId: String) async throws

    // Grouping
    func groupPlayers(coordinatorId: String, memberIds: [String]) async throws
    func ungroupPlayer(playerId: String) async throws

    // Cloud (favorites/playlists)
    func startOAuth(from context: ASWebAuthenticationPresentationContextProviding)
    func loadFavorites() async throws
    func loadPlaylists() async throws
    func playFavorite(groupId: String, favoriteId: String) async throws
    func playPlaylist(groupId: String, playlistId: String) async throws
    func unlinkCloud()
}
```

### Keychain Storage
- `sonos-accessToken` — cloud API access token
- `sonos-refreshToken` — cloud API refresh token
- `sonos-clientId` — developer app client ID
- `sonos-clientSecret` — developer app client secret

### UserDefaults
- `sonos-tokenExpiresAt` — non-sensitive expiry timestamp
- `sonos-householdId` — cached household ID (non-sensitive)

### App Wiring (LutronHomeApp.swift)
```swift
@State private var sonos = SonosManager()
// .environment(sonos)
// .onChange(of: scenePhase):
//   .active → sonos.resume()
//   .background → sonos.suspendLocal()
```

## iOS UI

### ContentView — Dashboard
- `SonosPill` in the unified control section (same layout as ThermostatPill)
- Shows: speaker name, track title + artist, play/pause state icon
- Tap opens `SonosDetailView` sheet
- One pill per group coordinator (not per individual speaker)

### SonosDetailView (sheet)
- **Now-playing card:** large album art, track title, artist, album
- **Progress bar:** current position / duration, scrubbable via drag
- **Transport row:** previous, play/pause, next buttons
- **Volume slider:** per-speaker volume with mute toggle
- **Queue section:** expandable list of upcoming tracks, swipe-to-remove
- **Group section:** current group members, buttons to add/remove speakers
- **Favorites section:** grid of favorites with cover art (only shown if cloud linked). Tap to start playback.

### SettingsView
- Sonos section showing discovered speakers (name, model, IP)
- Cloud API credentials: client ID + client secret fields
- "Link Sonos Account" button → OAuth flow via ASWebAuthenticationSession
- If linked: "Connected" status, "Unlink" button
- Cloud linking is optional — all local features work without it

### RoomDetailView
- If a Sonos speaker's room name matches the Lutron room, show a now-playing mini card (track + play/pause button)

## Credential Security

| Secret | Storage | Never in |
|--------|---------|----------|
| OAuth access token | Keychain | UserDefaults, logs, source |
| OAuth refresh token | Keychain | UserDefaults, logs, source |
| Client ID | Keychain (user-entered) | source, logs |
| Client secret | Keychain (user-entered) | source, logs |
| Household ID | UserDefaults (non-sensitive) | — |

## Verification

### Build
```bash
cd ios/LutronHome && xcodebuild -project LutronHome.xcodeproj -scheme LutronHome -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build
```

### Functional Testing
1. Launch app on same WiFi as Sonos speakers
2. Speakers should appear in dashboard within a few seconds (SSDP discovery)
3. Start music on a speaker via the Sonos app → now-playing should appear in LutronHome
4. Transport controls: play/pause/skip/previous → verify speaker responds
5. Volume slider → verify volume changes on speaker
6. Group two speakers → verify group appears correctly, transport controls affect group
7. Link Sonos cloud account in Settings → favorites should load
8. Tap a favorite → verify playback starts on selected speaker
9. Background the app → return → verify state refreshes correctly
