import Foundation
import Network

// MARK: - SonosLocalClient

actor SonosLocalClient {

    // MARK: - Types

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
    var onTopologyChange: ((Data) -> Void)?  // raw ZoneGroupState data for re-parsing

    // MARK: - Bonjour Discovery

    func discoverPlayers() async -> [SonosPlayer] {
        let endpoints = await browseBonjourEndpoints()

        // Resolve all endpoints in parallel
        let resolved: [(String, NWEndpoint)] = await withTaskGroup(of: (String?, NWEndpoint).self) { group in
            for endpoint in endpoints {
                group.addTask { (await self.resolveEndpointIP(endpoint), endpoint) }
            }
            var results: [(String, NWEndpoint)] = []
            for await (ip, ep) in group {
                if let ip { results.append((ip, ep)) }
            }
            return results
        }

        // Deduplicate by IP and fetch device descriptions in parallel
        var seenIPs = Set<String>()
        var uniqueIPs: [String] = []
        for (ip, _) in resolved {
            if seenIPs.insert(ip).inserted { uniqueIPs.append(ip) }
        }

        return await withTaskGroup(of: SonosPlayer?.self) { group in
            for ip in uniqueIPs {
                group.addTask {
                    let location = "http://\(ip):1400/xml/device_description.xml"
                    return await self.fetchDeviceDescription(location: location)
                }
            }
            var players: [SonosPlayer] = []
            for await player in group {
                if let player { players.append(player) }
            }
            return players
        }
    }

    private func browseBonjourEndpoints() async -> [NWEndpoint] {
        // Use a thread-safe collector for Bonjour results with early-exit
        final class EndpointCollector: @unchecked Sendable {
            var endpoints: [NWEndpoint] = []
            let lock = NSLock()
            var quietTimer: DispatchWorkItem?
            var hardTimer: DispatchWorkItem?
            var didResume = false

            func add(_ endpoint: NWEndpoint) {
                lock.lock()
                defer { lock.unlock() }
                endpoints.append(endpoint)
            }

            func getAll() -> [NWEndpoint] {
                lock.lock()
                defer { lock.unlock() }
                return endpoints
            }
        }

        let collector = EndpointCollector()

        return await withCheckedContinuation { continuation in
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: "_sonos._tcp", domain: nil), using: params)

            let finish = { [collector] in
                collector.lock.lock()
                guard !collector.didResume else { collector.lock.unlock(); return }
                collector.didResume = true
                collector.quietTimer?.cancel()
                collector.hardTimer?.cancel()
                let results = collector.endpoints
                collector.lock.unlock()
                browser.cancel()
                continuation.resume(returning: results)
            }

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    collector.add(result.endpoint)
                }
                // Reset quiet timer — finish 0.5s after last result
                collector.lock.lock()
                collector.quietTimer?.cancel()
                let quiet = DispatchWorkItem { finish() }
                collector.quietTimer = quiet
                collector.lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5, execute: quiet)
            }

            browser.start(queue: DispatchQueue(label: "sonos-bonjour"))

            // Hard cap at 3 seconds
            let hard = DispatchWorkItem { finish() }
            collector.lock.lock()
            collector.hardTimer = hard
            collector.lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: hard)
        }
    }

    private func resolveEndpointIP(_ endpoint: NWEndpoint) async -> String? {
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)
            nonisolated(unsafe) var resumed = false

            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    // Extract the resolved IP from the connection's current path
                    if let path = connection.currentPath,
                       let remoteEndpoint = path.remoteEndpoint,
                       case .hostPort(let host, _) = remoteEndpoint {
                        resumed = true
                        connection.cancel()
                        // Convert NWEndpoint.Host to string, stripping IPv6 scope if present
                        let hostStr = "\(host)"
                        let ip = hostStr.contains("%") ? String(hostStr.prefix(while: { $0 != "%" })) : hostStr
                        continuation.resume(returning: ip)
                    } else {
                        resumed = true
                        connection.cancel()
                        continuation.resume(returning: nil)
                    }
                case .failed, .cancelled:
                    resumed = true
                    continuation.resume(returning: nil)
                default:
                    break
                }
            }

            connection.start(queue: DispatchQueue(label: "sonos-resolve"))

            // Timeout after 2 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(returning: nil)
            }
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
        request.timeoutInterval = 5

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

        let decoded = metaXML
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")

        let title = (SimpleXMLParser.extractValue(fromString: decoded, tag: "dc:title") ?? "").xmlDecoded
        let artist = (SimpleXMLParser.extractValue(fromString: decoded, tag: "dc:creator") ?? "").xmlDecoded
        let album = (SimpleXMLParser.extractValue(fromString: decoded, tag: "upnp:album") ?? "").xmlDecoded
        let artPath = (SimpleXMLParser.extractValue(fromString: decoded, tag: "upnp:albumArtURI") ?? "").xmlDecoded

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

    // MARK: - Content Browsing

    func browseFavorites(player: SonosPlayer) async throws -> [SonosContentItem] {
        let (items, _) = try await browseFavoritesWithRaw(player: player)
        return items
    }

    func browseFavoritesWithRaw(player: SonosPlayer) async throws -> ([SonosContentItem], Data) {
        let data = try await soapRequest(
            baseURL: player.baseURL, path: contentDirectoryPath,
            service: contentDirectoryService, action: "Browse",
            body: """
                <ObjectID>FV:2</ObjectID>
                <BrowseFlag>BrowseDirectChildren</BrowseFlag>
                <Filter>*</Filter>
                <StartingIndex>0</StartingIndex>
                <RequestedCount>100</RequestedCount>
                <SortCriteria></SortCriteria>
                """
        )
        return (FavoritesBrowseParser(data: data, playerBaseURL: player.baseURL).parse(), data)
    }

    func browseContent(player: SonosPlayer, objectID: String, start: Int = 0, count: Int = 100) async throws -> [SonosContentItem] {
        let escapedID = objectID
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let data = try await soapRequest(
            baseURL: player.baseURL, path: contentDirectoryPath,
            service: contentDirectoryService, action: "Browse",
            body: """
                <ObjectID>\(escapedID)</ObjectID>
                <BrowseFlag>BrowseDirectChildren</BrowseFlag>
                <Filter>dc:title,res,dc:creator,upnp:artist,upnp:album,upnp:albumArtURI,upnp:class</Filter>
                <StartingIndex>\(start)</StartingIndex>
                <RequestedCount>\(count)</RequestedCount>
                <SortCriteria></SortCriteria>
                """
        )
        return ContentBrowseParser(data: data, playerBaseURL: player.baseURL).parse()
    }

    func getMusicServices(player: SonosPlayer) async throws -> [SonosMusicService] {
        let service = "urn:schemas-upnp-org:service:MusicServices:1"
        let data = try await soapRequest(
            baseURL: player.baseURL, path: "/MusicServices/Control",
            service: service, action: "ListAvailableServices",
            body: ""
        )
        return MusicServicesParser(data: data).parse()
    }

    func setAVTransportURI(player: SonosPlayer, uri: String, metadata: String = "") async throws {
        let escapedURI = uri
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let escapedMeta = metadata
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        _ = try await soapRequest(
            baseURL: player.baseURL, path: avTransportPath,
            service: avTransportService, action: "SetAVTransportURI",
            body: "<InstanceID>0</InstanceID><CurrentURI>\(escapedURI)</CurrentURI><CurrentURIMetaData>\(escapedMeta)</CurrentURIMetaData>"
        )
    }

    func addURIToQueue(player: SonosPlayer, uri: String, metadata: String = "") async throws {
        let escapedURI = uri
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let escapedMeta = metadata
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        _ = try await soapRequest(
            baseURL: player.baseURL, path: avTransportPath,
            service: avTransportService, action: "AddURIToQueue",
            body: """
                <InstanceID>0</InstanceID>
                <EnqueuedURI>\(escapedURI)</EnqueuedURI>
                <EnqueuedURIMetaData>\(escapedMeta)</EnqueuedURIMetaData>
                <DesiredFirstTrackNumberEnqueued>0</DesiredFirstTrackNumberEnqueued>
                <EnqueueAsNext>1</EnqueueAsNext>
                """
        )
    }

    // MARK: - Grouping

    func groupPlayer(member: SonosPlayer, withCoordinator coordinator: SonosPlayer) async throws {
        print("SonosLocalClient: groupPlayer — \(member.name) (\(member.id)) → x-rincon:\(coordinator.id) via \(member.baseURL)")
        let data = try await soapRequest(
            baseURL: member.baseURL, path: avTransportPath,
            service: avTransportService, action: "SetAVTransportURI",
            body: "<InstanceID>0</InstanceID><CurrentURI>x-rincon:\(coordinator.id)</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>"
        )
        if let resp = String(data: data, encoding: .utf8) {
            print("SonosLocalClient: groupPlayer response — \(resp.prefix(500))")
        }
    }

    func ungroupPlayer(player: SonosPlayer) async throws {
        print("SonosLocalClient: ungroupPlayer — \(player.name) (\(player.id)) via \(player.baseURL)")
        let data = try await soapRequest(
            baseURL: player.baseURL, path: avTransportPath,
            service: avTransportService, action: "BecomeCoordinatorOfStandaloneGroup",
            body: "<InstanceID>0</InstanceID>"
        )
        if let resp = String(data: data, encoding: .utf8) {
            print("SonosLocalClient: ungroupPlayer response — \(resp.prefix(500))")
        }
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

    func startListener() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handleIncomingConnection(connection) }
        }

        let port: UInt16 = await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    print("SonosLocalClient: listener failed — \(error)")
                    continuation.resume(returning: 0)
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "sonos-event-listener"))
        }

        self.httpListener = listener
        self.listenerPort = port
        return port
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
            async let s1: Void = subscribe(player: player, service: "AVTransport",
                              path: "/MediaRenderer/AVTransport/Event", callbackPort: callbackPort)
            async let s2: Void = subscribe(player: player, service: "RenderingControl",
                              path: "/MediaRenderer/RenderingControl/Event", callbackPort: callbackPort)
            async let s3: Void = subscribe(player: player, service: "ZoneGroupTopology",
                              path: "/ZoneGroupTopology/Event", callbackPort: callbackPort)
            _ = try await (s1, s2, s3)
        } catch {
            print("SonosLocalClient: subscription failed for \(player.name) — \(error)")
        }
    }

    func startRenewalTimer() {
        renewalTask?.cancel()
        renewalTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1500))
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

    private func handleIncomingConnection(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "sonos-event-conn"))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            if let data {
                Task { await self?.processEventNotification(data: data) }
            }
            let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func processEventNotification(data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }

        let parts = text.components(separatedBy: "\r\n\r\n")
        guard parts.count >= 2 else { return }

        let bodyStr = parts.dropFirst().joined(separator: "\r\n\r\n")

        if bodyStr.contains("TransportState") {
            let decoded = bodyStr
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")

            let stateStr = SimpleXMLParser.extractAttribute(fromString: decoded, tag: "TransportState", attribute: "val")
                ?? SimpleXMLParser.extractValue(fromString: decoded, tag: "TransportState") ?? ""
            let state: PlaybackState
            switch stateStr {
            case "PLAYING": state = .playing
            case "PAUSED_PLAYBACK": state = .paused
            case "TRANSITIONING": state = .transitioning
            default: state = .stopped
            }

            // Track metadata is double-encoded: the val attribute of CurrentTrackMetaData
            // contains entity-encoded DIDL-Lite XML that needs a second decode pass
            let rawMeta = SimpleXMLParser.extractAttribute(fromString: decoded, tag: "CurrentTrackMetaData", attribute: "val") ?? ""
            let metaDecoded = rawMeta
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")

            let title = SimpleXMLParser.extractValue(fromString: metaDecoded, tag: "dc:title")?.xmlDecoded
            let artist = SimpleXMLParser.extractValue(fromString: metaDecoded, tag: "dc:creator")?.xmlDecoded
            let album = SimpleXMLParser.extractValue(fromString: metaDecoded, tag: "upnp:album")?.xmlDecoded
            let artPath = SimpleXMLParser.extractValue(fromString: metaDecoded, tag: "upnp:albumArtURI")?.xmlDecoded

            let sid = extractHeaderValue(from: text, header: "SID") ?? ""
            let playerId = playerIdForSID(sid)

            // Resolve album art URL using the player's base URL from the subscription
            let playerBase = subscriptions.first(where: { $0.sid == sid })?.playerBaseURL
            let albumArtURL: URL? = {
                guard let artPath, !artPath.isEmpty else { return nil }
                if artPath.hasPrefix("http") { return URL(string: artPath) }
                if let base = playerBase { return URL(string: "\(base)\(artPath)") }
                return nil
            }()

            var track: SonosTrack?
            if let title, !title.isEmpty {
                track = SonosTrack(title: title, artist: artist ?? "", album: album ?? "",
                                  albumArtURL: albumArtURL, duration: 0, position: 0)
            }
            if let playerId {
                onTransportEvent?(playerId, state, track)
            }

        } else if bodyStr.contains("ZoneGroupState") {
            // Topology change — groups were added/removed/changed
            let decoded = bodyStr
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")

            // The ZoneGroupState is embedded in the event body; pass raw data for parsing
            if let data = decoded.data(using: .utf8) {
                onTopologyChange?(data)
            }

        } else if bodyStr.contains("Volume") && !bodyStr.contains("ZoneGroup") {
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
    }

    private func playerIdForSID(_ sid: String) -> String? {
        guard let sub = subscriptions.first(where: { $0.sid == sid }) else { return nil }
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
    static func extractValue(from data: Data, tag: String) -> String? {
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        return extractValue(fromString: str, tag: tag)
    }

    static func extractValue(fromString str: String, tag: String) -> String? {
        let openTag = "<\(tag)>"
        let closeTag = "</\(tag)>"
        let openTagWithAttr = "<\(tag) "

        if let openRange = str.range(of: openTag) {
            if let closeRange = str.range(of: closeTag, range: openRange.upperBound..<str.endIndex) {
                return String(str[openRange.upperBound..<closeRange.lowerBound])
            }
        }
        if let openRange = str.range(of: openTagWithAttr) {
            if let tagEnd = str.range(of: ">", range: openRange.upperBound..<str.endIndex) {
                if let closeRange = str.range(of: closeTag, range: tagEnd.upperBound..<str.endIndex) {
                    return String(str[tagEnd.upperBound..<closeRange.lowerBound])
                }
            }
        }
        return nil
    }

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
            // Only take the first (root device) UDN — sub-devices have _MS/_MR suffixes
            if info.uuid.isEmpty {
                info.uuid = trimmed.replacingOccurrences(of: "uuid:", with: "")
            }
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

// MARK: - Content Browse Parser

private class ContentBrowseParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let playerBaseURL: String
    private var items: [SonosContentItem] = []
    private var currentElement = ""
    private var currentText = ""
    private var currentTitle = ""
    private var currentArtist = ""
    private var currentAlbum = ""
    private var currentArtURI = ""
    private var currentClass = ""
    private var currentResURI = ""
    private var currentItemID = ""
    private var currentParentID = ""
    private var inItem = false

    init(data: Data, playerBaseURL: String) {
        self.data = data
        self.playerBaseURL = playerBaseURL
    }

    func parse() -> [SonosContentItem] {
        guard let resultXML = SimpleXMLParser.extractValue(from: data, tag: "Result") else { return [] }
        let decoded = resultXML
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")

        let parser = XMLParser(data: Data(decoded.utf8))
        parser.delegate = self
        parser.parse()
        return items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
        if elementName == "container" || elementName == "item" {
            inItem = true
            currentTitle = ""
            currentArtist = ""
            currentAlbum = ""
            currentArtURI = ""
            currentClass = ""
            currentResURI = ""
            currentItemID = attributes["id"] ?? ""
            currentParentID = attributes["parentID"] ?? ""
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
        case "upnp:class": currentClass = trimmed
        case "res": currentResURI = trimmed
        case "container", "item":
            inItem = false
            let isContainer = elementName == "container" || currentClass.contains("container")
            items.append(SonosContentItem(
                id: currentItemID,
                parentID: currentParentID,
                title: currentTitle,
                artist: currentArtist,
                album: currentAlbum,
                albumArtURI: currentArtURI,
                isContainer: isContainer,
                uri: currentResURI,
                metadata: ""
            ))
        default: break
        }
    }
}

// MARK: - Favorites Browse Parser

private class FavoritesBrowseParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let playerBaseURL: String
    private var items: [SonosContentItem] = []
    private var currentElement = ""
    private var currentText = ""
    private var currentTitle = ""
    private var currentArtURI = ""
    private var currentResURI = ""
    private var currentResMD = ""
    private var currentItemID = ""
    private var currentParentID = ""
    private var currentType = ""
    private var inItem = false

    init(data: Data, playerBaseURL: String) {
        self.data = data
        self.playerBaseURL = playerBaseURL
    }

    func parse() -> [SonosContentItem] {
        guard let resultXML = SimpleXMLParser.extractValue(from: data, tag: "Result") else { return [] }
        let decoded = resultXML
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")

        let parser = XMLParser(data: Data(decoded.utf8))
        parser.delegate = self
        parser.parse()
        return items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
        if elementName == "item" {
            inItem = true
            currentTitle = ""
            currentArtURI = ""
            currentResURI = ""
            currentResMD = ""
            currentType = ""
            currentItemID = attributes["id"] ?? ""
            currentParentID = attributes["parentID"] ?? ""
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
        case "upnp:albumArtURI": currentArtURI = trimmed
        case "res": currentResURI = trimmed
        case "r:resMD":
            // The metadata is double-escaped in the XML
            currentResMD = trimmed
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
        case "r:type": currentType = trimmed
        case "item":
            inItem = false
            // Skip shortcuts without a URI (Sonos Radio shortcuts need SMAPI)
            guard currentType == "instantPlay" && !currentResURI.isEmpty else { return }
            items.append(SonosContentItem(
                id: currentItemID,
                parentID: currentParentID,
                title: currentTitle,
                artist: "",
                album: "",
                albumArtURI: currentArtURI,
                isContainer: false,
                uri: currentResURI,
                metadata: currentResMD
            ))
        default: break
        }
    }
}

// MARK: - Music Services Parser

private class MusicServicesParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var services: [SonosMusicService] = []

    init(data: Data) {
        self.data = data
    }

    func parse() -> [SonosMusicService] {
        guard let descriptorList = SimpleXMLParser.extractValue(from: data, tag: "AvailableServiceDescriptorList") else {
            return []
        }
        let decoded = descriptorList
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")

        // Only surface services users commonly browse
        let wantedServices: Set<Int> = [12, 201, 204, 239, 254, 284, 236, 174, 303, 160, 233, 37]
        // 12=Spotify, 201=Amazon Music, 204=Apple Music, 239=Audible,
        // 254=TuneIn, 284=YouTube Music, 236=Pandora, 174=TIDAL,
        // 303=Sonos Radio, 160=SoundCloud, 233=Pocket Casts, 37=SiriusXM

        let pattern = "<Service[^>]+Id=\"(\\d+)\"[^>]+Name=\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(decoded.startIndex..., in: decoded)
        let matches = regex.matches(in: decoded, range: range)

        for match in matches {
            guard let typeRange = Range(match.range(at: 1), in: decoded),
                  let nameRange = Range(match.range(at: 2), in: decoded) else { continue }
            let typeId = Int(decoded[typeRange]) ?? 0
            guard wantedServices.contains(typeId) else { continue }
            let name = String(decoded[nameRange])
            let containerID = "SA_RINCON\(typeId)_"
            services.append(SonosMusicService(id: typeId, name: name, containerID: containerID))
        }
        // Sort: Spotify first, then Audible, then alphabetical
        let priority: [Int: Int] = [12: 0, 239: 1, 201: 2, 204: 3]
        services.sort { (priority[$0.id] ?? 99) < (priority[$1.id] ?? 99) }
        return services
    }
}
