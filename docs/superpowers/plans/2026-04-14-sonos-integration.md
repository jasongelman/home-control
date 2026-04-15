# Sonos Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Sonos speaker control to the iOS app via local UPnP/SOAP discovery + transport + optional cloud REST for favorites/playlists.

**Architecture:** iOS-only integration (no server/web). `SonosLocalClient` handles SSDP discovery, SOAP commands, and UPnP event subscriptions via a local HTTP listener. `SonosCloudClient` handles OAuth + REST for browsing favorites/playlists. `SonosManager` is the top-level `@Observable` that owns both clients and publishes unified state.

**Tech Stack:** Swift, SwiftUI, Observation framework, Network framework (NWConnection for UDP multicast), Foundation (URLSession for SOAP/REST), XMLParser, KeychainHelper, ASWebAuthenticationSession

---

## File Structure

| File | Responsibility |
|------|---------------|
| `SonosModels.swift` (create) | `SonosPlayer`, `SonosTrack`, `SonosFavorite`, `PlaybackState`, `RepeatMode`, `SonosTopologyCache` |
| `SonosLocalClient.swift` (create) | SSDP discovery, SOAP transport/volume/queue/grouping, UPnP event listener (local HTTP server), XML parsing |
| `SonosCloudClient.swift` (create) | OAuth2 flow via ASWebAuthenticationSession, REST favorites/playlists/playback, token refresh |
| `SonosManager.swift` (create) | `@Observable` coordinator owning both clients, publishes unified state, topology cache, position polling |
| `SonosDetailView.swift` (create) | Full-screen sheet with now-playing, transport, volume, queue, grouping, favorites |
| `ContentView.swift` (modify) | Add `SonosPill` + `.sonosPlayer` DashboardItem case + wire into `unifiedControlSection` |
| `RoomDetailView.swift` (modify) | Add per-room now-playing mini card for matching Sonos speakers |
| `SettingsView.swift` (modify) | Add Sonos settings section (discovered speakers, cloud credentials, link/unlink) |
| `LutronHomeApp.swift` (modify) | Add `@State private var sonos = SonosManager()`, `.environment(sonos)`, scenePhase wiring |
| `project.pbxproj` (modify) | Register all 5 new Swift files |

---

### Task 1: Data Models (`SonosModels.swift`)

**Files:**
- Create: `ios/LutronHome/LutronHome/SonosModels.swift`
- Modify: `ios/LutronHome/LutronHome.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create SonosModels.swift**

```swift
import Foundation

// MARK: - Enums

enum PlaybackState: String, Codable {
    case playing, paused, stopped, transitioning
}

enum RepeatMode: String, Codable {
    case off, all, one
}

// MARK: - SonosTrack

struct SonosTrack: Identifiable, Codable, Equatable {
    var id: String { "\(title)-\(artist)-\(album)" }
    let title: String
    let artist: String
    let album: String
    let albumArtURL: URL?
    var duration: TimeInterval
    var position: TimeInterval
}

// MARK: - SonosPlayer

struct SonosPlayer: Identifiable, Codable {
    let id: String           // UPnP device UUID
    var name: String         // Room name from device description XML
    var ipAddress: String
    var port: Int            // usually 1400
    var isCoordinator: Bool
    var groupId: String
    var groupMembers: [String]
    var state: PlaybackState
    var currentTrack: SonosTrack?
    var volume: Int          // 0-100
    var isMuted: Bool
    var shuffle: Bool
    var repeatMode: RepeatMode
    var modelName: String
    var modelNumber: String

    var baseURL: String { "http://\(ipAddress):\(port)" }
}

// MARK: - SonosFavorite

struct SonosFavorite: Identifiable, Codable {
    let id: String
    let name: String
    let imageURL: URL?
    let type: String  // playlist, station, album, etc.
}

// MARK: - Topology Cache

struct SonosTopologyCache: Codable {
    var players: [SonosPlayer]
    var lastUpdated: Date
}
```

- [ ] **Step 2: Register in project.pbxproj**

Add these 3 lines to the pbxproj:

1. In `/* Begin PBXBuildFile section */` (after the `A1000025` EcobeeManager line):
```
		A1000050 /* SonosModels.swift in Sources */ = {isa = PBXBuildFile; fileRef = A2000050 /* SonosModels.swift */; };
```

2. In `/* Begin PBXFileReference section */` (after the `A2000025` EcobeeManager line):
```
		A2000050 /* SonosModels.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SonosModels.swift; sourceTree = "<group>"; };
```

3. In the `children` array of the LutronHome group (after `A2000025 /* EcobeeManager.swift */,`):
```
				A2000050 /* SonosModels.swift */,
```

4. In `/* Begin PBXSourcesBuildPhase section */` `files` array (after `A1000025 /* EcobeeManager.swift in Sources */,`):
```
				A1000050 /* SonosModels.swift in Sources */,
```

- [ ] **Step 3: Build check**

Run: `cd ios/LutronHome && xcodebuild -project LutronHome.xcodeproj -scheme LutronHome -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add ios/LutronHome/LutronHome/SonosModels.swift ios/LutronHome/LutronHome.xcodeproj/project.pbxproj
git commit -m "feat(sonos): add data models — SonosPlayer, SonosTrack, SonosFavorite"
```

---

### Task 2: Local Client — SSDP Discovery + SOAP Commands (`SonosLocalClient.swift`)

**Files:**
- Create: `ios/LutronHome/LutronHome/SonosLocalClient.swift`
- Modify: `ios/LutronHome/LutronHome.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create SonosLocalClient.swift**

This is the largest file. It contains: SSDP multicast discovery, device description XML fetching, SOAP command execution for transport/volume/queue/grouping, a local HTTP listener for UPnP event notifications, and XML parsing helpers.

```swift
import Foundation
import Network

// MARK: - SonosLocalClient

actor SonosLocalClient {

    // MARK: - Types

    struct DiscoveredDevice {
        let location: String  // e.g. http://192.168.1.x:1400/xml/device_description.xml
    }

    struct EventSubscription {
        let sid: String
        let service: String
        let playerBaseURL: String
        let expiresAt: Date
    }

    // MARK: - State

    private var httpListener: NWListener?
    private var listenerPort: UInt16 = 0
    private var subscriptions: [EventSubscription] = []
    private var renewalTask: Task<Void, Never>?

    // Callbacks
    var onPlayersDiscovered: (([SonosPlayer]) -> Void)?
    var onTransportEvent: ((String, PlaybackState, SonosTrack?) -> Void)?  // playerId, state, track
    var onVolumeEvent: ((String, Int, Bool) -> Void)?  // playerId, volume, isMuted
    var onTopologyEvent: (([SonosPlayer]) -> Void)?

    // MARK: - SSDP Discovery

    func discoverPlayers() async -> [SonosPlayer] {
        let devices = await sendSSDPSearch()
        var players: [SonosPlayer] = []
        for device in devices {
            if let player = await fetchDeviceDescription(location: device.location) {
                players.append(player)
            }
        }
        return players
    }

    private func sendSSDPSearch() async -> [DiscoveredDevice] {
        let searchTarget = "urn:schemas-upnp-org:device:ZonePlayer:1"
        let message = """
            M-SEARCH * HTTP/1.1\r
            HOST: 239.255.255.250:1900\r
            MAN: "ssdp:discover"\r
            MX: 3\r
            ST: \(searchTarget)\r
            \r

            """
        let messageData = Data(message.utf8)

        return await withCheckedContinuation { continuation in
            var devices: [DiscoveredDevice] = []
            var seenLocations = Set<String>()

            let queue = DispatchQueue(label: "ssdp-discovery")
            let group = NWConnectionGroup(
                with: try! NWMulticastGroup(for: [
                    .hostPort(host: "239.255.255.250", port: 1900)
                ]),
                using: .udp
            )

            // Also send via a regular UDP socket for broader compatibility
            let connection = NWConnection(
                host: "239.255.255.250",
                port: 1900,
                using: .udp
            )

            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.send(content: messageData, completion: .contentProcessed { _ in })
                }
            }

            connection.receiveMessage { data, _, _, _ in
                self.handleSSDPResponse(data: data, devices: &devices, seen: &seenLocations)
                // Keep receiving
                self.receiveMore(connection: connection, devices: &devices, seen: &seenLocations)
            }

            connection.start(queue: queue)

            // Wait 3 seconds for responses, then return
            queue.asyncAfter(deadline: .now() + 3) {
                connection.cancel()
                continuation.resume(returning: devices)
            }
        }
    }

    private nonisolated func handleSSDPResponse(data: Data?, devices: inout [DiscoveredDevice], seen: inout Set<String>) {
        guard let data, let response = String(data: data, encoding: .utf8) else { return }
        // Parse LOCATION header
        for line in response.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("location:") {
                let location = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)
                if !seen.contains(location) {
                    seen.insert(location)
                    devices.append(DiscoveredDevice(location: location))
                }
            }
        }
    }

    private nonisolated func receiveMore(connection: NWConnection, devices: inout [DiscoveredDevice], seen: inout Set<String>) {
        connection.receiveMessage { [self] data, _, _, _ in
            self.handleSSDPResponse(data: data, devices: &devices, seen: &seen)
            self.receiveMore(connection: connection, devices: &devices, seen: &seen)
        }
    }

    private func fetchDeviceDescription(location: String) async -> SonosPlayer? {
        guard let url = URL(string: location) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return parseDeviceDescriptionXML(data: data, location: location)
        } catch {
            print("SonosLocalClient: failed to fetch device description from \(location) — \(error)")
            return nil
        }
    }

    private func parseDeviceDescriptionXML(data: Data, location: String) -> SonosPlayer? {
        let parser = DeviceDescriptionParser(data: data)
        guard let info = parser.parse() else { return nil }

        // Extract IP and port from location URL
        guard let url = URL(string: location),
              let host = url.host,
              let port = url.port else { return nil }

        return SonosPlayer(
            id: info.uuid,
            name: info.roomName,
            ipAddress: host,
            port: port,
            isCoordinator: true,
            groupId: info.uuid,
            groupMembers: [],
            state: .stopped,
            currentTrack: nil,
            volume: 0,
            isMuted: false,
            shuffle: false,
            repeatMode: .off,
            modelName: info.modelName,
            modelNumber: info.modelNumber
        )
    }

    // MARK: - SOAP Commands

    private func soapRequest(baseURL: String, path: String, service: String, action: String, body: String) async throws -> Data {
        let urlString = "\(baseURL)\(path)"
        guard let url = URL(string: urlString) else {
            throw SonosError.invalidURL(urlString)
        }

        let soapEnvelope = """
            <?xml version="1.0" encoding="utf-8"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
                <s:Body>
                    <u:\(action) xmlns:u="\(service)">
                        \(body)
                    </u:\(action)>
                </s:Body>
            </s:Envelope>
            """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(soapEnvelope.utf8)
        request.timeoutInterval = 10

        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    // MARK: - Transport Controls (AVTransport)

    private let avTransportService = "urn:schemas-upnp-org:service:AVTransport:1"
    private let avTransportPath = "/MediaRenderer/AVTransport/Control"

    func play(player: SonosPlayer) async throws {
        _ = try await soapRequest(
            baseURL: player.baseURL, path: avTransportPath,
            service: avTransportService, action: "Play",
            body: "<InstanceID>0</InstanceID><Speed>1</Speed>"
        )
    }

    func pause(player: SonosPlayer) async throws {
        _ = try await soapRequest(
            baseURL: player.baseURL, path: avTransportPath,
            service: avTransportService, action: "Pause",
            body: "<InstanceID>0</InstanceID>"
        )
    }

    func stop(player: SonosPlayer) async throws {
        _ = try await soapRequest(
            baseURL: player.baseURL, path: avTransportPath,
            service: avTransportService, action: "Stop",
            body: "<InstanceID>0</InstanceID>"
        )
    }

    func next(player: SonosPlayer) async throws {
        _ = try await soapRequest(
            baseURL: player.baseURL, path: avTransportPath,
            service: avTransportService, action: "Next",
            body: "<InstanceID>0</InstanceID>"
        )
    }

    func previous(player: SonosPlayer) async throws {
        _ = try await soapRequest(
            baseURL: player.baseURL, path: avTransportPath,
            service: avTransportService, action: "Previous",
            body: "<InstanceID>0</InstanceID>"
        )
    }

    func seek(player: SonosPlayer, position: TimeInterval) async throws {
        let hours = Int(position) / 3600
        let minutes = (Int(position) % 3600) / 60
        let seconds = Int(position) % 60
        let target = String(format: "%d:%02d:%02d", hours, minutes, seconds)
        _ = try await soapRequest(
            baseURL: player.baseURL, path: avTransportPath,
            service: avTransportService, action: "Seek",
            body: "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>\(target)</Target>"
        )
    }

    // MARK: - Volume Controls (RenderingControl)

    private let renderingControlService = "urn:schemas-upnp-org:service:RenderingControl:1"
    private let renderingControlPath = "/MediaRenderer/RenderingControl/Control"

    func setVolume(player: SonosPlayer, level: Int) async throws {
        let clamped = max(0, min(100, level))
        _ = try await soapRequest(
            baseURL: player.baseURL, path: renderingControlPath,
            service: renderingControlService, action: "SetVolume",
            body: "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>\(clamped)</DesiredVolume>"
        )
    }

    func setMute(player: SonosPlayer, muted: Bool) async throws {
        _ = try await soapRequest(
            baseURL: player.baseURL, path: renderingControlPath,
            service: renderingControlService, action: "SetMute",
            body: "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredMute>\(muted ? 1 : 0)</DesiredMute>"
        )
    }

    func getVolume(player: SonosPlayer) async throws -> Int {
        let data = try await soapRequest(
            baseURL: player.baseURL, path: renderingControlPath,
            service: renderingControlService, action: "GetVolume",
            body: "<InstanceID>0</InstanceID><Channel>Master</Channel>"
        )
        let value = SimpleXMLParser.extractValue(from: data, tag: "CurrentVolume")
        return Int(value ?? "0") ?? 0
    }

    func getMute(player: SonosPlayer) async throws -> Bool {
        let data = try await soapRequest(
            baseURL: player.baseURL, path: renderingControlPath,
            service: renderingControlService, action: "GetMute",
            body: "<InstanceID>0</InstanceID><Channel>Master</Channel>"
        )
        let value = SimpleXMLParser.extractValue(from: data, tag: "CurrentMute")
        return value == "1"
    }

    // MARK: - State Polling

    func getTransportInfo(player: SonosPlayer) async throws -> PlaybackState {
        let data = try await soapRequest(
            baseURL: player.baseURL, path: avTransportPath,
            service: avTransportService, action: "GetTransportInfo",
            body: "<InstanceID>0</InstanceID>"
        )
        let stateStr = SimpleXMLParser.extractValue(from: data, tag: "CurrentTransportState") ?? "STOPPED"
        switch stateStr {
        case "PLAYING": return .playing
        case "PAUSED_PLAYBACK": return .paused
        case "TRANSITIONING": return .transitioning
        default: return .stopped
        }
    }

    func getPositionInfo(player: SonosPlayer) async throws -> SonosTrack? {
        let data = try await soapRequest(
            baseURL: player.baseURL, path: avTransportPath,
            service: avTransportService, action: "GetPositionInfo",
            body: "<InstanceID>0</InstanceID>"
        )
        return parsePositionInfo(data: data, playerBaseURL: player.baseURL)
    }

    private func parsePositionInfo(data: Data, playerBaseURL: String) -> SonosTrack? {
        let duration = SimpleXMLParser.extractValue(from: data, tag: "TrackDuration") ?? "0:00:00"
        let position = SimpleXMLParser.extractValue(from: data, tag: "RelTime") ?? "0:00:00"
        let metaXML = SimpleXMLParser.extractValue(from: data, tag: "TrackMetaData") ?? ""

        // Decode HTML entities in the metadata
        let decoded = metaXML
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")

        let title = SimpleXMLParser.extractValue(fromString: decoded, tag: "dc:title") ?? ""
        let artist = SimpleXMLParser.extractValue(fromString: decoded, tag: "dc:creator") ?? ""
        let album = SimpleXMLParser.extractValue(fromString: decoded, tag: "upnp:album") ?? ""
        let artPath = SimpleXMLParser.extractValue(fromString: decoded, tag: "upnp:albumArtURI") ?? ""

        guard !title.isEmpty else { return nil }

        let albumArtURL: URL?
        if artPath.hasPrefix("http") {
            albumArtURL = URL(string: artPath)
        } else if !artPath.isEmpty {
            albumArtURL = URL(string: "\(playerBaseURL)\(artPath)")
        } else {
            albumArtURL = nil
        }

        return SonosTrack(
            title: title,
            artist: artist,
            album: album,
            albumArtURL: albumArtURL,
            duration: parseTimeString(duration),
            position: parseTimeString(position)
        )
    }

    // MARK: - Queue (ContentDirectory)

    private let contentDirectoryService = "urn:schemas-upnp-org:service:ContentDirectory:1"
    private let contentDirectoryPath = "/MediaServer/ContentDirectory/Control"

    func getQueue(player: SonosPlayer) async throws -> [SonosTrack] {
        let data = try await soapRequest(
            baseURL: player.baseURL, path: contentDirectoryPath,
            service: contentDirectoryService, action: "Browse",
            body: """
                <ObjectID>Q:0</ObjectID>
                <BrowseFlag>BrowseDirectChildren</BrowseFlag>
                <Filter>dc:title,res,dc:creator,upnp:artist,upnp:album,upnp:albumArtURI</Filter>
                <StartingIndex>0</StartingIndex>
                <RequestedCount>100</RequestedCount>
                <SortCriteria></SortCriteria>
                """
        )
        return QueueParser(data: data, playerBaseURL: player.baseURL).parse()
    }

    func removeFromQueue(player: SonosPlayer, index: Int) async throws {
        _ = try await soapRequest(
            baseURL: player.baseURL, path: avTransportPath,
            service: avTransportService, action: "RemoveTrackFromQueue",
            body: "<InstanceID>0</InstanceID><ObjectID>Q:0/\(index + 1)</ObjectID>"
        )
    }

    func clearQueue(player: SonosPlayer) async throws {
        _ = try await soapRequest(
            baseURL: player.baseURL, path: avTransportPath,
            service: avTransportService, action: "RemoveAllTracksFromQueue",
            body: "<InstanceID>0</InstanceID>"
        )
    }

    // MARK: - Grouping

    func groupPlayer(member: SonosPlayer, withCoordinator coordinator: SonosPlayer) async throws {
        _ = try await soapRequest(
            baseURL: member.baseURL, path: avTransportPath,
            service: avTransportService, action: "SetAVTransportURI",
            body: "<InstanceID>0</InstanceID><CurrentURI>x-rincon:\(coordinator.id)</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>"
        )
    }

    func ungroupPlayer(player: SonosPlayer) async throws {
        _ = try await soapRequest(
            baseURL: player.baseURL, path: avTransportPath,
            service: avTransportService, action: "BecomeCoordinatorOfStandaloneGroup",
            body: "<InstanceID>0</InstanceID>"
        )
    }

    // MARK: - Zone Group Topology

    func getZoneGroupState(player: SonosPlayer) async throws -> Data {
        let service = "urn:schemas-upnp-org:service:ZoneGroupTopology:1"
        return try await soapRequest(
            baseURL: player.baseURL, path: "/ZoneGroupTopology/Control",
            service: service, action: "GetZoneGroupState",
            body: ""
        )
    }

    // MARK: - UPnP Event Listener

    func startListener() throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleIncomingConnection(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("SonosLocalClient: listener failed — \(error)")
            }
        }
        listener.start(queue: DispatchQueue(label: "sonos-event-listener"))

        // Wait briefly for the port to be assigned
        var actualPort: UInt16 = 0
        if case .ready = listener.state, let port = listener.port {
            actualPort = port.rawValue
        } else {
            // Give it a moment
            Thread.sleep(forTimeInterval: 0.1)
            actualPort = listener.port?.rawValue ?? 0
        }

        self.httpListener = listener
        self.listenerPort = actualPort
        return actualPort
    }

    func stopListener() {
        httpListener?.cancel()
        httpListener = nil
        listenerPort = 0
        renewalTask?.cancel()
        renewalTask = nil
        subscriptions.removeAll()
    }

    // MARK: - UPnP Event Subscriptions

    func subscribe(player: SonosPlayer, service: String, path: String, callbackPort: UInt16) async throws {
        let urlString = "\(player.baseURL)\(path)"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "SUBSCRIBE"
        // Get the device's local IP to construct callback URL
        let callbackURL = "<http://\(getLocalIPAddress()):\(callbackPort)/notify>"
        request.setValue(callbackURL, forHTTPHeaderField: "CALLBACK")
        request.setValue("upnp:event", forHTTPHeaderField: "NT")
        request.setValue("Second-1800", forHTTPHeaderField: "TIMEOUT")

        let (_, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           let sid = httpResponse.value(forHTTPHeaderField: "SID") {
            let sub = EventSubscription(
                sid: sid,
                service: service,
                playerBaseURL: player.baseURL,
                expiresAt: Date().addingTimeInterval(1800)
            )
            subscriptions.append(sub)
        }
    }

    func subscribeAll(player: SonosPlayer, callbackPort: UInt16) async {
        do {
            try await subscribe(player: player, service: "AVTransport",
                              path: "/MediaRenderer/AVTransport/Event", callbackPort: callbackPort)
            try await subscribe(player: player, service: "RenderingControl",
                              path: "/MediaRenderer/RenderingControl/Event", callbackPort: callbackPort)
            try await subscribe(player: player, service: "ZoneGroupTopology",
                              path: "/ZoneGroupTopology/Event", callbackPort: callbackPort)
        } catch {
            print("SonosLocalClient: subscription failed for \(player.name) — \(error)")
        }
    }

    func startRenewalTimer() {
        renewalTask?.cancel()
        renewalTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1500)) // Renew at 25 min (before 30 min expiry)
                guard !Task.isCancelled else { return }
                await self?.renewSubscriptions()
            }
        }
    }

    private func renewSubscriptions() async {
        for sub in subscriptions {
            let urlString: String
            switch sub.service {
            case "AVTransport": urlString = "\(sub.playerBaseURL)/MediaRenderer/AVTransport/Event"
            case "RenderingControl": urlString = "\(sub.playerBaseURL)/MediaRenderer/RenderingControl/Event"
            case "ZoneGroupTopology": urlString = "\(sub.playerBaseURL)/ZoneGroupTopology/Event"
            default: continue
            }
            guard let url = URL(string: urlString) else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "SUBSCRIBE"
            request.setValue(sub.sid, forHTTPHeaderField: "SID")
            request.setValue("Second-1800", forHTTPHeaderField: "TIMEOUT")
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    // MARK: - Incoming Event Handling

    private nonisolated func handleIncomingConnection(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "sonos-event-conn"))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            if let data {
                Task { await self?.processEventNotification(data: data) }
            }
            // Send 200 OK response
            let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func processEventNotification(data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }

        // Split HTTP headers from body
        let parts = text.components(separatedBy: "\r\n\r\n")
        guard parts.count >= 2 else { return }
        let bodyData = Data(parts.dropFirst().joined(separator: "\r\n\r\n").utf8)

        // Determine event type from the XML content
        let bodyStr = parts.dropFirst().joined(separator: "\r\n\r\n")

        if bodyStr.contains("TransportState") {
            // AVTransport event
            let decoded = bodyStr
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")

            let stateStr = SimpleXMLParser.extractValue(fromString: decoded, tag: "TransportState") ?? ""
            let state: PlaybackState
            switch stateStr {
            case "PLAYING": state = .playing
            case "PAUSED_PLAYBACK": state = .paused
            case "TRANSITIONING": state = .transitioning
            default: state = .stopped
            }

            // Extract track metadata if present
            let title = SimpleXMLParser.extractValue(fromString: decoded, tag: "dc:title")
            let artist = SimpleXMLParser.extractValue(fromString: decoded, tag: "dc:creator")
            let album = SimpleXMLParser.extractValue(fromString: decoded, tag: "upnp:album")

            var track: SonosTrack?
            if let title, !title.isEmpty {
                track = SonosTrack(title: title, artist: artist ?? "", album: album ?? "",
                                  albumArtURL: nil, duration: 0, position: 0)
            }

            // We don't know the player ID from the event alone — the SonosManager
            // maps events to players by correlating the subscription SID from headers
            let sid = extractHeaderValue(from: text, header: "SID") ?? ""
            let playerId = playerIdForSID(sid)
            if let playerId {
                onTransportEvent?(playerId, state, track)
            }

        } else if bodyStr.contains("Volume") && !bodyStr.contains("ZoneGroup") {
            // RenderingControl event
            let decoded = bodyStr
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")

            let volStr = SimpleXMLParser.extractAttribute(fromString: decoded, tag: "Volume", attribute: "val")
                ?? SimpleXMLParser.extractValue(fromString: decoded, tag: "Volume") ?? ""
            let muteStr = SimpleXMLParser.extractAttribute(fromString: decoded, tag: "Mute", attribute: "val")
                ?? SimpleXMLParser.extractValue(fromString: decoded, tag: "Mute") ?? ""

            let sid = extractHeaderValue(from: text, header: "SID") ?? ""
            if let playerId = playerIdForSID(sid) {
                let volume = Int(volStr) ?? -1
                let muted = muteStr == "1"
                if volume >= 0 {
                    onVolumeEvent?(playerId, volume, muted)
                }
            }
        }
        // ZoneGroupTopology events are complex XML — handled via periodic polling instead
    }

    private func playerIdForSID(_ sid: String) -> String? {
        guard let sub = subscriptions.first(where: { $0.sid == sid }) else { return nil }
        // Extract player ID from the base URL by looking up known players
        // This is resolved by the manager layer
        return sub.playerBaseURL
    }

    private func extractHeaderValue(from text: String, header: String) -> String? {
        for line in text.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix(header.lowercased() + ":") {
                return String(line.dropFirst(header.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - Helpers

    func getLocalIPAddress() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return address }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
            }
        }
        return address
    }

    private func parseTimeString(_ str: String) -> TimeInterval {
        let parts = str.components(separatedBy: ":")
        guard parts.count == 3,
              let h = Double(parts[0]),
              let m = Double(parts[1]),
              let s = Double(parts[2]) else { return 0 }
        return h * 3600 + m * 60 + s
    }
}

// MARK: - Errors

enum SonosError: Error, LocalizedError {
    case invalidURL(String)
    case soapFault(String)
    case noCoordinator

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid Sonos URL: \(url)"
        case .soapFault(let msg): return "Sonos SOAP error: \(msg)"
        case .noCoordinator: return "No group coordinator found"
        }
    }
}

// MARK: - XML Parsing Helpers

enum SimpleXMLParser {
    /// Extract the text content of the first occurrence of a tag from Data
    static func extractValue(from data: Data, tag: String) -> String? {
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        return extractValue(fromString: str, tag: tag)
    }

    /// Extract the text content of the first occurrence of a tag from a String
    static func extractValue(fromString str: String, tag: String) -> String? {
        let openTag = "<\(tag)>"
        let closeTag = "</\(tag)>"
        // Also check for tags with attributes
        let openTagWithAttr = "<\(tag) "

        if let openRange = str.range(of: openTag) {
            if let closeRange = str.range(of: closeTag, range: openRange.upperBound..<str.endIndex) {
                return String(str[openRange.upperBound..<closeRange.lowerBound])
            }
        }
        // Try with attributes
        if let openRange = str.range(of: openTagWithAttr) {
            // Find the end of the opening tag
            if let tagEnd = str.range(of: ">", range: openRange.upperBound..<str.endIndex) {
                if let closeRange = str.range(of: closeTag, range: tagEnd.upperBound..<str.endIndex) {
                    return String(str[tagEnd.upperBound..<closeRange.lowerBound])
                }
            }
        }
        return nil
    }

    /// Extract an attribute value from a tag
    static func extractAttribute(fromString str: String, tag: String, attribute: String) -> String? {
        let pattern = "<\(tag)[^>]*\\s\(attribute)=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
              let range = Range(match.range(at: 1), in: str) else { return nil }
        return String(str[range])
    }
}

// MARK: - Device Description XML Parser

private class DeviceDescriptionParser: NSObject, XMLParserDelegate {
    struct DeviceInfo {
        var uuid: String = ""
        var roomName: String = ""
        var modelName: String = ""
        var modelNumber: String = ""
    }

    private let data: Data
    private var info = DeviceInfo()
    private var currentElement = ""
    private var currentText = ""

    init(data: Data) {
        self.data = data
    }

    func parse() -> DeviceInfo? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse() ? info : nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "roomName": info.roomName = trimmed
        case "modelName": info.modelName = trimmed
        case "modelNumber": info.modelNumber = trimmed
        case "UDN":
            // UDN is like "uuid:RINCON_xxxx"
            info.uuid = trimmed.replacingOccurrences(of: "uuid:", with: "")
        default: break
        }
    }
}

// MARK: - Queue XML Parser

private class QueueParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let playerBaseURL: String
    private var tracks: [SonosTrack] = []
    private var currentElement = ""
    private var currentText = ""
    private var currentTitle = ""
    private var currentArtist = ""
    private var currentAlbum = ""
    private var currentArtURI = ""
    private var currentDuration = ""
    private var inItem = false

    init(data: Data, playerBaseURL: String) {
        self.data = data
        self.playerBaseURL = playerBaseURL
    }

    func parse() -> [SonosTrack] {
        // The queue response has the actual DIDL-Lite XML inside a Result tag, HTML-encoded
        guard let resultXML = SimpleXMLParser.extractValue(from: data, tag: "Result") else { return [] }
        let decoded = resultXML
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")

        let parser = XMLParser(data: Data(decoded.utf8))
        parser.delegate = self
        parser.parse()
        return tracks
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
        if elementName == "item" {
            inItem = true
            currentTitle = ""
            currentArtist = ""
            currentAlbum = ""
            currentArtURI = ""
            currentDuration = ""
        }
        if elementName == "res", let dur = attributes["duration"] {
            currentDuration = dur
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        guard inItem else { return }
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "dc:title": currentTitle = trimmed
        case "dc:creator": currentArtist = trimmed
        case "upnp:album": currentAlbum = trimmed
        case "upnp:albumArtURI": currentArtURI = trimmed
        case "item":
            inItem = false
            let artURL: URL?
            if currentArtURI.hasPrefix("http") {
                artURL = URL(string: currentArtURI)
            } else if !currentArtURI.isEmpty {
                artURL = URL(string: "\(playerBaseURL)\(currentArtURI)")
            } else {
                artURL = nil
            }
            let dur = parseTimeString(currentDuration)
            tracks.append(SonosTrack(title: currentTitle, artist: currentArtist,
                                     album: currentAlbum, albumArtURL: artURL,
                                     duration: dur, position: 0))
        default: break
        }
    }

    private func parseTimeString(_ str: String) -> TimeInterval {
        let parts = str.components(separatedBy: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return 0 }
        return h * 3600 + m * 60 + s
    }
}
```

- [ ] **Step 2: Register in project.pbxproj**

Add 4 lines (same pattern as Task 1, using IDs `A1000051`/`A2000051`):

1. PBXBuildFile: `A1000051 /* SonosLocalClient.swift in Sources */ = {isa = PBXBuildFile; fileRef = A2000051 /* SonosLocalClient.swift */; };`
2. PBXFileReference: `A2000051 /* SonosLocalClient.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SonosLocalClient.swift; sourceTree = "<group>"; };`
3. Group children: `A2000051 /* SonosLocalClient.swift */,`
4. Sources build phase: `A1000051 /* SonosLocalClient.swift in Sources */,`

- [ ] **Step 3: Build check**

Run: `cd ios/LutronHome && xcodebuild -project LutronHome.xcodeproj -scheme LutronHome -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add ios/LutronHome/LutronHome/SonosLocalClient.swift ios/LutronHome/LutronHome.xcodeproj/project.pbxproj
git commit -m "feat(sonos): add local client — SSDP discovery, SOAP commands, UPnP events"
```

---

### Task 3: Cloud Client — OAuth + REST (`SonosCloudClient.swift`)

**Files:**
- Create: `ios/LutronHome/LutronHome/SonosCloudClient.swift`
- Modify: `ios/LutronHome/LutronHome.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create SonosCloudClient.swift**

```swift
import Foundation
import AuthenticationServices

actor SonosCloudClient {

    // MARK: - Token State

    private(set) var accessToken: String?
    private(set) var refreshToken: String?
    private(set) var clientId: String?
    private(set) var clientSecret: String?
    private(set) var householdId: String?
    private var tokenExpiresAt: Date?

    // Keychain keys
    private enum Keys {
        static let accessToken = "sonos-accessToken"
        static let refreshToken = "sonos-refreshToken"
        static let clientId = "sonos-clientId"
        static let clientSecret = "sonos-clientSecret"
    }

    // UserDefaults keys
    private enum DefaultsKeys {
        static let tokenExpiresAt = "sonos-tokenExpiresAt"
        static let householdId = "sonos-householdId"
    }

    var isLinked: Bool { accessToken != nil }

    // MARK: - Init

    init() {
        accessToken = KeychainHelper.loadString(for: Keys.accessToken)
        refreshToken = KeychainHelper.loadString(for: Keys.refreshToken)
        clientId = KeychainHelper.loadString(for: Keys.clientId)
        clientSecret = KeychainHelper.loadString(for: Keys.clientSecret)
        householdId = UserDefaults.standard.string(forKey: DefaultsKeys.householdId)
        if let interval = UserDefaults.standard.object(forKey: DefaultsKeys.tokenExpiresAt) as? Double {
            tokenExpiresAt = Date(timeIntervalSince1970: interval)
        }
    }

    // MARK: - Credential Management

    func setClientCredentials(clientId: String, clientSecret: String) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        KeychainHelper.save(clientId, for: Keys.clientId)
        KeychainHelper.save(clientSecret, for: Keys.clientSecret)
    }

    func unlink() {
        accessToken = nil
        refreshToken = nil
        tokenExpiresAt = nil
        householdId = nil
        KeychainHelper.delete(for: Keys.accessToken)
        KeychainHelper.delete(for: Keys.refreshToken)
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.tokenExpiresAt)
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.householdId)
    }

    // MARK: - OAuth Flow

    @MainActor
    func startOAuth(from context: ASWebAuthenticationPresentationContextProviding) async throws {
        guard let clientId, !clientId.isEmpty else {
            throw SonosCloudError.missingCredentials
        }

        let redirectURI = "com.jasongelman.lutronhome://oauth/sonos"
        let state = UUID().uuidString
        let scope = "playback-control-all"

        let authURL = URL(string: "https://api.sonos.com/login/v3/oauth?client_id=\(clientId)&response_type=code&redirect_uri=\(redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? redirectURI)&scope=\(scope)&state=\(state)")!

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "com.jasongelman.lutronhome") { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: SonosCloudError.oauthCancelled)
                }
            }
            session.presentationContextProvider = context
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }

        // Extract authorization code
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw SonosCloudError.noAuthCode
        }

        // Exchange code for tokens
        try await exchangeCodeForTokens(code: code, redirectURI: redirectURI)

        // Fetch household ID
        try await fetchHouseholdId()
    }

    private func exchangeCodeForTokens(code: String, redirectURI: String) async throws {
        guard let clientId, let clientSecret else {
            throw SonosCloudError.missingCredentials
        }

        let url = URL(string: "https://api.sonos.com/login/v3/oauth/access")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Basic auth header
        let credentials = "\(clientId):\(clientSecret)"
        let base64Credentials = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")

        let body = "grant_type=authorization_code&code=\(code)&redirect_uri=\(redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? redirectURI)"
        request.httpBody = Data(body.utf8)

        let (data, _) = try await URLSession.shared.data(for: request)

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Int
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        saveTokens(access: tokenResponse.access_token, refresh: tokenResponse.refresh_token,
                   expiresIn: tokenResponse.expires_in)
    }

    func refreshAccessToken() async throws {
        guard let refreshToken, let clientId, let clientSecret else {
            throw SonosCloudError.missingCredentials
        }

        let url = URL(string: "https://api.sonos.com/login/v3/oauth/access")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let credentials = "\(clientId):\(clientSecret)"
        let base64Credentials = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")

        let body = "grant_type=refresh_token&refresh_token=\(refreshToken)"
        request.httpBody = Data(body.utf8)

        let (data, _) = try await URLSession.shared.data(for: request)

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Int
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        saveTokens(access: tokenResponse.access_token, refresh: tokenResponse.refresh_token,
                   expiresIn: tokenResponse.expires_in)
    }

    private func saveTokens(access: String, refresh: String, expiresIn: Int) {
        accessToken = access
        refreshToken = refresh
        tokenExpiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        KeychainHelper.save(access, for: Keys.accessToken)
        KeychainHelper.save(refresh, for: Keys.refreshToken)
        UserDefaults.standard.set(tokenExpiresAt!.timeIntervalSince1970, forKey: DefaultsKeys.tokenExpiresAt)
    }

    // MARK: - Ensure Valid Token

    private func ensureValidToken() async throws {
        guard accessToken != nil else { throw SonosCloudError.notLinked }
        if let expiresAt = tokenExpiresAt, Date() > expiresAt.addingTimeInterval(-300) {
            try await refreshAccessToken()
        }
    }

    private func authorizedRequest(url: URL) async throws -> URLRequest {
        try await ensureValidToken()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - Households

    private func fetchHouseholdId() async throws {
        let url = URL(string: "https://api.ws.sonos.com/control/api/v1/households")!
        let request = try await authorizedRequest(url: url)
        let (data, _) = try await URLSession.shared.data(for: request)

        struct HouseholdsResponse: Decodable {
            struct Household: Decodable { let id: String }
            let households: [Household]
        }

        let response = try JSONDecoder().decode(HouseholdsResponse.self, from: data)
        guard let household = response.households.first else {
            throw SonosCloudError.noHousehold
        }
        householdId = household.id
        UserDefaults.standard.set(household.id, forKey: DefaultsKeys.householdId)
    }

    // MARK: - Favorites

    func getFavorites() async throws -> [SonosFavorite] {
        guard let householdId else { throw SonosCloudError.noHousehold }
        let url = URL(string: "https://api.ws.sonos.com/control/api/v1/households/\(householdId)/favorites")!
        let request = try await authorizedRequest(url: url)
        let (data, _) = try await URLSession.shared.data(for: request)

        struct FavoritesResponse: Decodable {
            struct Item: Decodable {
                let id: String
                let name: String
                let imageUrl: String?
                let service: FavService?
            }
            struct FavService: Decodable {
                let name: String?
            }
            let items: [Item]?
        }

        let response = try JSONDecoder().decode(FavoritesResponse.self, from: data)
        return (response.items ?? []).map { item in
            SonosFavorite(
                id: item.id,
                name: item.name,
                imageURL: item.imageUrl.flatMap { URL(string: $0) },
                type: item.service?.name ?? "unknown"
            )
        }
    }

    // MARK: - Playlists

    func getPlaylists() async throws -> [SonosFavorite] {
        guard let householdId else { throw SonosCloudError.noHousehold }
        let url = URL(string: "https://api.ws.sonos.com/control/api/v1/households/\(householdId)/playlists")!
        let request = try await authorizedRequest(url: url)
        let (data, _) = try await URLSession.shared.data(for: request)

        struct PlaylistsResponse: Decodable {
            struct Playlist: Decodable {
                let id: String
                let name: String
            }
            let playlists: [Playlist]?
        }

        let response = try JSONDecoder().decode(PlaylistsResponse.self, from: data)
        return (response.playlists ?? []).map { pl in
            SonosFavorite(id: pl.id, name: pl.name, imageURL: nil, type: "playlist")
        }
    }

    // MARK: - Play Favorite/Playlist

    func playFavorite(groupId: String, favoriteId: String) async throws {
        let url = URL(string: "https://api.ws.sonos.com/control/api/v1/groups/\(groupId)/favorites")!
        var request = try await authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["favoriteId": favoriteId, "playOnCompletion": true] as [String: Any]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            throw SonosCloudError.apiError(httpResponse.statusCode)
        }
    }

    func playPlaylist(groupId: String, playlistId: String) async throws {
        let url = URL(string: "https://api.ws.sonos.com/control/api/v1/groups/\(groupId)/playlists")!
        var request = try await authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["playlistId": playlistId, "playOnCompletion": true] as [String: Any]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            throw SonosCloudError.apiError(httpResponse.statusCode)
        }
    }
}

// MARK: - Errors

enum SonosCloudError: Error, LocalizedError {
    case missingCredentials
    case oauthCancelled
    case noAuthCode
    case notLinked
    case noHousehold
    case apiError(Int)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "Sonos client ID and secret are required"
        case .oauthCancelled: return "Sonos authorization was cancelled"
        case .noAuthCode: return "No authorization code received from Sonos"
        case .notLinked: return "Sonos cloud account not linked"
        case .noHousehold: return "No Sonos household found"
        case .apiError(let code): return "Sonos API error (HTTP \(code))"
        }
    }
}
```

- [ ] **Step 2: Register in project.pbxproj**

Add 4 lines (IDs `A1000052`/`A2000052`):

1. PBXBuildFile: `A1000052 /* SonosCloudClient.swift in Sources */ = {isa = PBXBuildFile; fileRef = A2000052 /* SonosCloudClient.swift */; };`
2. PBXFileReference: `A2000052 /* SonosCloudClient.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SonosCloudClient.swift; sourceTree = "<group>"; };`
3. Group children: `A2000052 /* SonosCloudClient.swift */,`
4. Sources build phase: `A1000052 /* SonosCloudClient.swift in Sources */,`

- [ ] **Step 3: Build check**

Run: `cd ios/LutronHome && xcodebuild -project LutronHome.xcodeproj -scheme LutronHome -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add ios/LutronHome/LutronHome/SonosCloudClient.swift ios/LutronHome/LutronHome.xcodeproj/project.pbxproj
git commit -m "feat(sonos): add cloud client — OAuth2 flow, favorites, playlists"
```

---

### Task 4: Manager — Observable Coordinator (`SonosManager.swift`)

**Files:**
- Create: `ios/LutronHome/LutronHome/SonosManager.swift`
- Modify: `ios/LutronHome/LutronHome.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create SonosManager.swift**

```swift
import Foundation
import Observation
import AuthenticationServices

@Observable
class SonosManager: @unchecked Sendable {
    // MARK: - Published State

    var players: [SonosPlayer] = []
    var favorites: [SonosFavorite] = []
    var playlists: [SonosFavorite] = []
    var isLoading = false
    var errorMessage: String?

    var isCloudLinked: Bool {
        _cloudLinked
    }
    var hasPlayers: Bool { !players.isEmpty }

    /// Group coordinators only (one pill per group, not per speaker)
    var coordinators: [SonosPlayer] {
        players.filter { $0.isCoordinator }
    }

    // MARK: - Private State

    private var _cloudLinked = false
    private let localClient = SonosLocalClient()
    private let cloudClient = SonosCloudClient()
    private var positionTimer: Timer?
    private var listenerPort: UInt16 = 0

    // Topology cache
    private var topologyCacheURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("sonos-topology.json")
    }

    // MARK: - Init

    init() {
        loadTopologyCache()
        Task { _cloudLinked = await cloudClient.isLinked }
    }

    // MARK: - Lifecycle

    func resume() {
        Task {
            // Start event listener
            do {
                listenerPort = try await localClient.startListener()
            } catch {
                print("SonosManager: failed to start event listener — \(error)")
            }

            // Set up event callbacks
            await setupEventCallbacks()

            // Discover speakers
            await discover()

            // Start position polling
            startPositionPolling()
        }
    }

    func suspendLocal() {
        positionTimer?.invalidate()
        positionTimer = nil
        Task {
            await localClient.stopListener()
        }
    }

    // MARK: - Discovery

    private func discover() async {
        let discovered = await localClient.discoverPlayers()
        guard !discovered.isEmpty else { return }

        // Fetch full state for each player
        var fullPlayers: [SonosPlayer] = []
        for var player in discovered {
            do {
                player.state = try await localClient.getTransportInfo(player: player)
                player.currentTrack = try await localClient.getPositionInfo(player: player)
                player.volume = try await localClient.getVolume(player: player)
                player.isMuted = try await localClient.getMute(player: player)
            } catch {
                print("SonosManager: failed to poll \(player.name) — \(error)")
            }
            fullPlayers.append(player)

            // Subscribe to events
            if listenerPort > 0 {
                await localClient.subscribeAll(player: player, callbackPort: listenerPort)
            }
        }

        // Parse zone group topology from any player to get group info
        if let firstPlayer = fullPlayers.first {
            do {
                let topoData = try await localClient.getZoneGroupState(player: firstPlayer)
                updateGroupTopology(data: topoData, players: &fullPlayers)
            } catch {
                print("SonosManager: failed to get topology — \(error)")
            }
        }

        await MainActor.run {
            self.players = fullPlayers
        }
        saveTopologyCache()

        // Start subscription renewal
        await localClient.startRenewalTimer()
    }

    private func updateGroupTopology(data: Data, players: inout [SonosPlayer]) {
        // Parse the ZoneGroupState XML to determine group membership
        guard let xmlStr = String(data: data, encoding: .utf8) else { return }
        let decoded = xmlStr
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")

        // Simple parsing: find ZoneGroup elements and their members
        // Each ZoneGroup has a Coordinator attribute and ZoneGroupMember children
        let groupPattern = "<ZoneGroup\\s+Coordinator=\"([^\"]+)\"[^>]*>(.*?)</ZoneGroup>"
        let memberPattern = "<ZoneGroupMember\\s+UUID=\"([^\"]+)\""

        guard let groupRegex = try? NSRegularExpression(pattern: groupPattern, options: .dotMatchesLineSeparators),
              let memberRegex = try? NSRegularExpression(pattern: memberPattern) else { return }

        let range = NSRange(decoded.startIndex..., in: decoded)
        let groupMatches = groupRegex.matches(in: decoded, range: range)

        for groupMatch in groupMatches {
            guard let coordRange = Range(groupMatch.range(at: 1), in: decoded),
                  let bodyRange = Range(groupMatch.range(at: 2), in: decoded) else { continue }

            let coordinatorUUID = String(decoded[coordRange])
            let groupBody = String(decoded[bodyRange])
            let bodyNSRange = NSRange(groupBody.startIndex..., in: groupBody)
            let memberMatches = memberRegex.matches(in: groupBody, range: bodyNSRange)

            var memberUUIDs: [String] = []
            for memberMatch in memberMatches {
                if let range = Range(memberMatch.range(at: 1), in: groupBody) {
                    memberUUIDs.append(String(groupBody[range]))
                }
            }

            let groupId = coordinatorUUID

            for i in players.indices {
                if memberUUIDs.contains(players[i].id) {
                    players[i].groupId = groupId
                    players[i].isCoordinator = (players[i].id == coordinatorUUID)
                    players[i].groupMembers = memberUUIDs.filter { $0 != players[i].id }
                }
            }
        }
    }

    // MARK: - Event Callbacks

    private func setupEventCallbacks() async {
        await localClient.setOnTransportEvent { [weak self] baseURL, state, track in
            Task { @MainActor in
                guard let self else { return }
                if let idx = self.players.firstIndex(where: { $0.baseURL == baseURL }) {
                    self.players[idx].state = state
                    if let track {
                        self.players[idx].currentTrack = track
                    }
                }
            }
        }

        await localClient.setOnVolumeEvent { [weak self] baseURL, volume, muted in
            Task { @MainActor in
                guard let self else { return }
                if let idx = self.players.firstIndex(where: { $0.baseURL == baseURL }) {
                    self.players[idx].volume = volume
                    self.players[idx].isMuted = muted
                }
            }
        }
    }

    // MARK: - Position Polling

    private func startPositionPolling() {
        positionTimer?.invalidate()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { await self?.pollPositions() }
        }
    }

    private func pollPositions() async {
        for player in players where player.state == .playing && player.isCoordinator {
            do {
                if let track = try await localClient.getPositionInfo(player: player) {
                    await MainActor.run {
                        if let idx = self.players.firstIndex(where: { $0.id == player.id }) {
                            self.players[idx].currentTrack = track
                        }
                    }
                }
            } catch {
                // Ignore polling errors
            }
        }
    }

    // MARK: - Transport Controls

    func play(playerId: String) async throws {
        guard let player = coordinator(for: playerId) else { throw SonosError.noCoordinator }
        try await localClient.play(player: player)
        await MainActor.run {
            if let idx = players.firstIndex(where: { $0.id == player.id }) {
                players[idx].state = .playing
            }
        }
    }

    func pausePlayback(playerId: String) async throws {
        guard let player = coordinator(for: playerId) else { throw SonosError.noCoordinator }
        try await localClient.pause(player: player)
        await MainActor.run {
            if let idx = players.firstIndex(where: { $0.id == player.id }) {
                players[idx].state = .paused
            }
        }
    }

    func next(playerId: String) async throws {
        guard let player = coordinator(for: playerId) else { throw SonosError.noCoordinator }
        try await localClient.next(player: player)
    }

    func previous(playerId: String) async throws {
        guard let player = coordinator(for: playerId) else { throw SonosError.noCoordinator }
        try await localClient.previous(player: player)
    }

    func seek(playerId: String, position: TimeInterval) async throws {
        guard let player = coordinator(for: playerId) else { throw SonosError.noCoordinator }
        try await localClient.seek(player: player, position: position)
    }

    // MARK: - Volume Controls

    func setVolume(playerId: String, level: Int) async throws {
        guard let player = players.first(where: { $0.id == playerId }) else { return }
        try await localClient.setVolume(player: player, level: level)
        await MainActor.run {
            if let idx = players.firstIndex(where: { $0.id == playerId }) {
                players[idx].volume = level
            }
        }
    }

    func setMute(playerId: String, muted: Bool) async throws {
        guard let player = players.first(where: { $0.id == playerId }) else { return }
        try await localClient.setMute(player: player, muted: muted)
        await MainActor.run {
            if let idx = players.firstIndex(where: { $0.id == playerId }) {
                players[idx].isMuted = muted
            }
        }
    }

    // MARK: - Queue

    func getQueue(playerId: String) async throws -> [SonosTrack] {
        guard let player = coordinator(for: playerId) else { throw SonosError.noCoordinator }
        return try await localClient.getQueue(player: player)
    }

    func removeFromQueue(playerId: String, index: Int) async throws {
        guard let player = coordinator(for: playerId) else { throw SonosError.noCoordinator }
        try await localClient.removeFromQueue(player: player, index: index)
    }

    func clearQueue(playerId: String) async throws {
        guard let player = coordinator(for: playerId) else { throw SonosError.noCoordinator }
        try await localClient.clearQueue(player: player)
    }

    // MARK: - Grouping

    func groupPlayers(coordinatorId: String, memberIds: [String]) async throws {
        guard let coordinator = players.first(where: { $0.id == coordinatorId }) else { return }
        for memberId in memberIds {
            guard let member = players.first(where: { $0.id == memberId }) else { continue }
            try await localClient.groupPlayer(member: member, withCoordinator: coordinator)
        }
        // Refresh topology
        try? await Task.sleep(for: .seconds(1))
        await discover()
    }

    func ungroupPlayer(playerId: String) async throws {
        guard let player = players.first(where: { $0.id == playerId }) else { return }
        try await localClient.ungroupPlayer(player: player)
        try? await Task.sleep(for: .seconds(1))
        await discover()
    }

    // MARK: - Cloud Features

    func setClientCredentials(clientId: String, clientSecret: String) {
        Task {
            await cloudClient.setClientCredentials(clientId: clientId, clientSecret: clientSecret)
        }
    }

    @MainActor
    func startOAuth(from context: ASWebAuthenticationPresentationContextProviding) {
        Task {
            do {
                try await cloudClient.startOAuth(from: context)
                _cloudLinked = true
                try await loadFavorites()
                try await loadPlaylists()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadFavorites() async throws {
        let favs = try await cloudClient.getFavorites()
        await MainActor.run { favorites = favs }
    }

    func loadPlaylists() async throws {
        let pls = try await cloudClient.getPlaylists()
        await MainActor.run { playlists = pls }
    }

    func playFavorite(groupId: String, favoriteId: String) async throws {
        try await cloudClient.playFavorite(groupId: groupId, favoriteId: favoriteId)
    }

    func playPlaylist(groupId: String, playlistId: String) async throws {
        try await cloudClient.playPlaylist(groupId: groupId, playlistId: playlistId)
    }

    func unlinkCloud() {
        Task {
            await cloudClient.unlink()
            await MainActor.run {
                _cloudLinked = false
                favorites = []
                playlists = []
            }
        }
    }

    // MARK: - Helpers

    private func coordinator(for playerId: String) -> SonosPlayer? {
        guard let player = players.first(where: { $0.id == playerId }) else { return nil }
        if player.isCoordinator { return player }
        return players.first(where: { $0.id == player.groupId })
    }

    /// Find the player for a given room name (for RoomDetailView integration)
    func player(forRoom roomName: String) -> SonosPlayer? {
        players.first(where: { $0.name.lowercased() == roomName.lowercased() })
    }

    // MARK: - Topology Cache

    private func loadTopologyCache() {
        guard let url = topologyCacheURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(SonosTopologyCache.self, from: data) else {
            return
        }
        players = cache.players
    }

    private func saveTopologyCache() {
        guard let url = topologyCacheURL else { return }
        let cache = SonosTopologyCache(players: players, lastUpdated: Date())
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: url, options: .atomic)
        } catch {
            print("SonosManager: failed to write topology cache — \(error.localizedDescription)")
        }
    }
}

// MARK: - Actor callback setters (bridging actor isolation)

extension SonosLocalClient {
    func setOnTransportEvent(_ handler: @escaping (String, PlaybackState, SonosTrack?) -> Void) {
        onTransportEvent = handler
    }
    func setOnVolumeEvent(_ handler: @escaping (String, Int, Bool) -> Void) {
        onVolumeEvent = handler
    }
}
```

- [ ] **Step 2: Register in project.pbxproj**

Add 4 lines (IDs `A1000053`/`A2000053`):

1. PBXBuildFile: `A1000053 /* SonosManager.swift in Sources */ = {isa = PBXBuildFile; fileRef = A2000053 /* SonosManager.swift */; };`
2. PBXFileReference: `A2000053 /* SonosManager.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SonosManager.swift; sourceTree = "<group>"; };`
3. Group children: `A2000053 /* SonosManager.swift */,`
4. Sources build phase: `A1000053 /* SonosManager.swift in Sources */,`

- [ ] **Step 3: Build check**

Run: `cd ios/LutronHome && xcodebuild -project LutronHome.xcodeproj -scheme LutronHome -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add ios/LutronHome/LutronHome/SonosManager.swift ios/LutronHome/LutronHome.xcodeproj/project.pbxproj
git commit -m "feat(sonos): add SonosManager — observable coordinator with topology cache"
```

---

### Task 5: Detail View (`SonosDetailView.swift`)

**Files:**
- Create: `ios/LutronHome/LutronHome/SonosDetailView.swift`
- Modify: `ios/LutronHome/LutronHome.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create SonosDetailView.swift**

```swift
import SwiftUI

struct SonosDetailView: View {
    let player: SonosPlayer
    @Environment(SonosManager.self) var sonos
    @Environment(\.dismiss) private var dismiss
    @State private var localVolume: Double
    @State private var queueTracks: [SonosTrack] = []
    @State private var showQueue = false
    @State private var showGrouping = false
    @State private var scrubPosition: Double?

    init(player: SonosPlayer) {
        self.player = player
        _localVolume = State(initialValue: Double(player.volume))
    }

    private var currentPlayer: SonosPlayer {
        sonos.players.first(where: { $0.id == player.id }) ?? player
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    nowPlayingCard
                    progressBar
                    transportRow
                    volumeSection
                    if showQueue { queueSection }
                    if showGrouping { groupSection }
                    if sonos.isCloudLinked && !sonos.favorites.isEmpty { favoritesSection }
                }
                .padding()
            }
            .navigationTitle(currentPlayer.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.orange)
                }
            }
        }
        .onAppear {
            Task {
                queueTracks = (try? await sonos.getQueue(playerId: player.id)) ?? []
            }
        }
        .onChange(of: currentPlayer.volume) { _, newValue in
            localVolume = Double(newValue)
        }
    }

    // MARK: - Now Playing Card

    private var nowPlayingCard: some View {
        VStack(spacing: 12) {
            if let track = currentPlayer.currentTrack {
                if let artURL = track.albumArtURL {
                    AsyncImage(url: artURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.tertiarySystemBackground))
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.secondary)
                            )
                    }
                    .frame(width: 240, height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Text(track.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !track.album.isEmpty {
                    Text(track.album)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 40)
                Text("Not Playing")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Progress Bar

    @ViewBuilder
    private var progressBar: some View {
        if let track = currentPlayer.currentTrack, track.duration > 0 {
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { scrubPosition ?? track.position },
                        set: { scrubPosition = $0 }
                    ),
                    in: 0...max(track.duration, 1)
                ) { editing in
                    if !editing, let pos = scrubPosition {
                        Task { try? await sonos.seek(playerId: player.id, position: pos) }
                        scrubPosition = nil
                    }
                }
                .tint(.orange)

                HStack {
                    Text(formatTime(scrubPosition ?? track.position))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatTime(track.duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Transport Row

    private var transportRow: some View {
        HStack(spacing: 32) {
            Button {
                Task { try? await sonos.previous(playerId: player.id) }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            Button {
                Task {
                    if currentPlayer.state == .playing {
                        try? await sonos.pausePlayback(playerId: player.id)
                    } else {
                        try? await sonos.play(playerId: player.id)
                    }
                }
            } label: {
                Image(systemName: currentPlayer.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)

            Button {
                Task { try? await sonos.next(playerId: player.id) }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Volume Section

    private var volumeSection: some View {
        VStack(spacing: 8) {
            // Show volume for each speaker in the group
            let groupPlayers = sonos.players.filter {
                $0.id == currentPlayer.id || currentPlayer.groupMembers.contains($0.id)
            }

            ForEach(groupPlayers) { gPlayer in
                HStack(spacing: 12) {
                    Button {
                        Task { try? await sonos.setMute(playerId: gPlayer.id, muted: !gPlayer.isMuted) }
                    } label: {
                        Image(systemName: gPlayer.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(gPlayer.isMuted ? .secondary : .orange)
                            .frame(width: 24)
                    }
                    .buttonStyle(.plain)

                    if groupPlayers.count > 1 {
                        Text(gPlayer.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)
                    }

                    Slider(
                        value: Binding(
                            get: { Double(gPlayer.volume) },
                            set: { newVal in
                                Task { try? await sonos.setVolume(playerId: gPlayer.id, level: Int(newVal)) }
                            }
                        ),
                        in: 0...100
                    )
                    .tint(.orange)

                    Text("\(gPlayer.volume)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Queue Section

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Queue")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                if !queueTracks.isEmpty {
                    Button("Clear") {
                        Task {
                            try? await sonos.clearQueue(playerId: player.id)
                            queueTracks = []
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }

            if queueTracks.isEmpty {
                Text("Queue is empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(queueTracks.enumerated()), id: \.offset) { index, track in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.caption)
                                .lineLimit(1)
                            Text(track.artist)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            Task {
                                try? await sonos.removeFromQueue(playerId: player.id, index: index)
                                queueTracks.remove(at: index)
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Group Section

    private var groupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speakers")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)

            ForEach(sonos.players) { p in
                let isInGroup = p.id == currentPlayer.id || currentPlayer.groupMembers.contains(p.id)
                HStack(spacing: 10) {
                    Image(systemName: isInGroup ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isInGroup ? .orange : .secondary)
                    Text(p.name)
                        .font(.subheadline)
                    Spacer()
                    if p.id != currentPlayer.id {
                        Button(isInGroup ? "Remove" : "Add") {
                            Task {
                                if isInGroup {
                                    try? await sonos.ungroupPlayer(playerId: p.id)
                                } else {
                                    try? await sonos.groupPlayers(coordinatorId: currentPlayer.id, memberIds: [p.id])
                                }
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(isInGroup ? .red : .orange)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Favorites Section

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Favorites")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(sonos.favorites) { fav in
                    Button {
                        Task { try? await sonos.playFavorite(groupId: currentPlayer.groupId, favoriteId: fav.id) }
                    } label: {
                        VStack(spacing: 6) {
                            if let imageURL = fav.imageURL {
                                AsyncImage(url: imageURL) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(.tertiarySystemBackground))
                                }
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(.tertiarySystemBackground))
                                    .frame(width: 80, height: 80)
                                    .overlay(
                                        Image(systemName: "music.note")
                                            .foregroundStyle(.secondary)
                                    )
                            }
                            Text(fav.name)
                                .font(.caption2)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Toggle Buttons (below transport)

    // These are integrated into the navigation bar or as inline toggles

    // MARK: - Helpers

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
```

- [ ] **Step 2: Register in project.pbxproj**

Add 4 lines (IDs `A1000054`/`A2000054`):

1. PBXBuildFile: `A1000054 /* SonosDetailView.swift in Sources */ = {isa = PBXBuildFile; fileRef = A2000054 /* SonosDetailView.swift */; };`
2. PBXFileReference: `A2000054 /* SonosDetailView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SonosDetailView.swift; sourceTree = "<group>"; };`
3. Group children: `A2000054 /* SonosDetailView.swift */,`
4. Sources build phase: `A1000054 /* SonosDetailView.swift in Sources */,`

- [ ] **Step 3: Build check**

Run: `cd ios/LutronHome && xcodebuild -project LutronHome.xcodeproj -scheme LutronHome -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add ios/LutronHome/LutronHome/SonosDetailView.swift ios/LutronHome/LutronHome.xcodeproj/project.pbxproj
git commit -m "feat(sonos): add SonosDetailView — now-playing, transport, volume, queue, favorites"
```

---

### Task 6: App Wiring + Dashboard Integration

**Files:**
- Modify: `ios/LutronHome/LutronHome/LutronHomeApp.swift`
- Modify: `ios/LutronHome/LutronHome/ContentView.swift`

- [ ] **Step 1: Wire SonosManager into LutronHomeApp.swift**

Add these changes to `LutronHomeApp.swift`:

1. Add `@State private var sonos = SonosManager()` after the `ecobee` line (line 14).
2. Add `.environment(sonos)` after `.environment(ecobee)` (line 30).
3. In the `.onChange(of: scenePhase)` block, after `ecobee.resume()` (line 50), add `sonos.resume()`.
4. In the same block, add a `.background` case to call `sonos.suspendLocal()`:

The `.onChange` block should become:
```swift
.onChange(of: scenePhase) { _, newPhase in
    homeKit.handleScenePhase(active: newPhase == .active)
    if newPhase == .active {
        if !store.isConnected { store.connect() }
        homeConnect.resume()
        myUplink.resume()
        smartHQ.resume()
        myQ.resume()
        totalConnect.resume()
        ecobee.resume()
        sonos.resume()
        // Sync appliance status to widget
        syncApplianceStatus()
    } else if newPhase == .background {
        sonos.suspendLocal()
    }
}
```

- [ ] **Step 2: Add SonosPill and DashboardItem to ContentView.swift**

In `ContentView.swift`, make these changes:

1. Add `@Environment(SonosManager.self) var sonos` in `DashboardView` (after the `ecobee` environment on line 287).

2. Add a new case to the `DashboardItem` enum (after `.thermostat(EcobeeThermostat)` on line 684):
```swift
case sonosPlayer(SonosPlayer)
```

3. Add the `id` case in `DashboardItem.id` (after the `.thermostat` case on line 696):
```swift
case .sonosPlayer(let p): return "sonos_\(p.id)"
```

4. In `dashboardItems`, after the thermostat block (after line 733), add:
```swift
// 2c. Sonos speakers (media — high priority like alarm/climate)
for player in sonos.coordinators where player.state == .playing || player.currentTrack != nil {
    guard items.count < maxItems else { break }
    items.append(.sonosPlayer(player))
}
```

5. In `unifiedControlSection`, after the `.thermostat` case (after line 908), add:
```swift
case .sonosPlayer(let player):
    SonosPill(player: player)
```

- [ ] **Step 3: Add SonosPill struct to ContentView.swift**

Add this after the `ThermostatPill` struct (after line 1482):

```swift
// MARK: - Sonos Pill

struct SonosPill: View {
    let player: SonosPlayer
    @Environment(SonosManager.self) var sonos
    @State private var showDetail = false

    var body: some View {
        Button { showDetail = true } label: {
            HStack(spacing: 10) {
                Image(systemName: player.state == .playing ? "speaker.wave.2.fill" : "speaker.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if let track = player.currentTrack {
                        HStack(spacing: 4) {
                            Text(track.title)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            if !track.artist.isEmpty {
                                Text("·")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text(track.artist)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    } else {
                        Text("Not Playing")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 6)

                // Inline play/pause button
                Button {
                    Task {
                        if player.state == .playing {
                            try? await sonos.pausePlayback(playerId: player.id)
                        } else {
                            try? await sonos.play(playerId: player.id)
                        }
                    }
                } label: {
                    Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .frame(width: 28, height: 28)
                        .background(Color.orange.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .frame(minHeight: 56)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.orange.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetail) {
            SonosDetailView(player: player)
        }
    }
}
```

- [ ] **Step 4: Build check**

Run: `cd ios/LutronHome && xcodebuild -project LutronHome.xcodeproj -scheme LutronHome -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add ios/LutronHome/LutronHome/LutronHomeApp.swift ios/LutronHome/LutronHome/ContentView.swift
git commit -m "feat(sonos): wire SonosManager + add SonosPill to dashboard"
```

---

### Task 7: Settings + RoomDetailView Integration

**Files:**
- Modify: `ios/LutronHome/LutronHome/SettingsView.swift`
- Modify: `ios/LutronHome/LutronHome/RoomDetailView.swift`

- [ ] **Step 1: Add Sonos section to SettingsView.swift**

Add `@Environment(SonosManager.self) var sonos` after the ecobee environment (line 12).

Add two new `@State` variables after `tcUserCode` (line 23):
```swift
@State private var sonosClientId: String = ""
@State private var sonosClientSecret: String = ""
```

Add the following section after the Climate/Ecobee section (after line 470) and before the Resideo section:

```swift
// MARK: - Sonos

Section {
    HStack {
        Image(systemName: "hifispeaker.2.fill")
            .foregroundStyle(.orange)
        Text("Sonos Speakers")
            .fontWeight(.medium)
        Spacer()
        if sonos.hasPlayers {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    if sonos.players.isEmpty {
        HStack {
            Text("Status")
            Spacer()
            Text("Discovering...")
                .foregroundStyle(.secondary)
        }
    } else {
        ForEach(sonos.players) { player in
            HStack {
                Image(systemName: "hifispeaker.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.name)
                    Text("\(player.modelName) · \(player.ipAddress)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if player.state == .playing {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .symbolEffect(.variableColor.iterative)
                }
            }
        }
    }

    // Cloud linking
    if !sonos.isCloudLinked {
        TextField("Sonos Client ID", text: $sonosClientId)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onChange(of: sonosClientId) { _, val in
                sonos.setClientCredentials(clientId: val, clientSecret: sonosClientSecret)
            }

        SecureField("Client Secret", text: $sonosClientSecret)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onChange(of: sonosClientSecret) { _, val in
                sonos.setClientCredentials(clientId: sonosClientId, clientSecret: val)
            }

        Button {
            sonos.startOAuth(from: oauthContext)
        } label: {
            HStack {
                Image(systemName: "link")
                Text("Link Sonos Account")
            }
        }
        .disabled(sonosClientId.isEmpty || sonosClientSecret.isEmpty)
        .tint(.orange)
    } else {
        HStack {
            Text("Cloud API")
            Spacer()
            Text("Connected")
                .foregroundStyle(.green)
        }

        Button(role: .destructive) {
            sonos.unlinkCloud()
        } label: {
            HStack {
                Image(systemName: "link.badge.plus")
                    .symbolRenderingMode(.multicolor)
                Text("Unlink Account")
            }
        }
    }

    if let error = sonos.errorMessage {
        Text(error)
            .font(.caption)
            .foregroundStyle(.red)
    }
} header: {
    Text("Sonos")
} footer: {
    Text("Speakers are discovered automatically on your local network. Cloud linking is optional — enables browsing favorites and playlists. Register at developer.sonos.com for credentials.")
}
```

In the `.onAppear` block (around line 611), add:
```swift
sonosClientId = KeychainHelper.loadString(for: "sonos-clientId") ?? ""
sonosClientSecret = KeychainHelper.loadString(for: "sonos-clientSecret") ?? ""
```

- [ ] **Step 2: Add Sonos mini card to RoomDetailView.swift**

Add `@Environment(SonosManager.self) var sonos` after the ecobee environment (line 5).

Add a computed property after `roomSensors` (after line 24):
```swift
private var roomSonosPlayer: SonosPlayer? {
    sonos.player(forRoom: roomName)
}
```

Add the following section in the `body` VStack, after the Climate section (after line 83) and before the lights section:

```swift
// Sonos speaker for this room
if let player = roomSonosPlayer {
    DeviceSection(title: "Music", icon: "hifispeaker.fill", count: 1) {
        HStack(spacing: 12) {
            Image(systemName: player.state == .playing ? "speaker.wave.2.fill" : "speaker.fill")
                .font(.system(size: 16))
                .foregroundStyle(.orange)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.name)
                    .font(.system(size: 13, weight: .medium))
                if let track = player.currentTrack {
                    Text("\(track.title) · \(track.artist)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Not Playing")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                Task {
                    if player.state == .playing {
                        try? await sonos.pausePlayback(playerId: player.id)
                    } else {
                        try? await sonos.play(playerId: player.id)
                    }
                }
            } label: {
                Image(systemName: player.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.separator).opacity(0.4), lineWidth: 0.5)
        )
    }
}
```

- [ ] **Step 3: Build check**

Run: `cd ios/LutronHome && xcodebuild -project LutronHome.xcodeproj -scheme LutronHome -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add ios/LutronHome/LutronHome/SettingsView.swift ios/LutronHome/LutronHome/RoomDetailView.swift
git commit -m "feat(sonos): add Settings section + RoomDetailView now-playing card"
```

---

### Task 8: Final Build Verification + Secrets Check

**Files:** None created/modified — verification only.

- [ ] **Step 1: Full build**

Run: `cd ios/LutronHome && xcodebuild -project LutronHome.xcodeproj -scheme LutronHome -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Secrets check**

Run: `git diff --cached` (should be empty) and check that no Sonos API keys, tokens, or secrets are in any tracked files. Verify:
- No hardcoded client IDs or secrets in Swift files
- Keychain keys are string constants, not actual values
- `sonos-topology.json` path is in Documents (runtime, not committed)

- [ ] **Step 3: Review all new files are registered in pbxproj**

Verify these 5 files appear in all 4 pbxproj sections (PBXBuildFile, PBXFileReference, group children, Sources build phase):
1. `SonosModels.swift` (A1000050/A2000050)
2. `SonosLocalClient.swift` (A1000051/A2000051)
3. `SonosCloudClient.swift` (A1000052/A2000052)
4. `SonosManager.swift` (A1000053/A2000053)
5. `SonosDetailView.swift` (A1000054/A2000054)
