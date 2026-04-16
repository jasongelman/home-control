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

    // MARK: - Bonjour Discovery

    func discoverPlayers() async -> [SonosPlayer] {
        let endpoints = await browseBonjourEndpoints()
        var players: [SonosPlayer] = []
        var seenIPs = Set<String>()

        for endpoint in endpoints {
            guard let ip = await resolveEndpointIP(endpoint) else { continue }
            guard !seenIPs.contains(ip) else { continue }
            seenIPs.insert(ip)

            let location = "http://\(ip):1400/xml/device_description.xml"
            if let player = await fetchDeviceDescription(location: location) {
                players.append(player)
            }
        }
        return players
    }

    private func browseBonjourEndpoints() async -> [NWEndpoint] {
        // Use a thread-safe collector for Bonjour results
        final class EndpointCollector: @unchecked Sendable {
            var endpoints: [NWEndpoint] = []
            let lock = NSLock()

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

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    collector.add(result.endpoint)
                }
            }

            browser.start(queue: DispatchQueue(label: "sonos-bonjour"))

            // Browse for 3 seconds, then return results
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                browser.cancel()
                continuation.resume(returning: collector.getAll())
            }
        }
    }

    private func resolveEndpointIP(_ endpoint: NWEndpoint) async -> String? {
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)
            var resumed = false

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
            guard let self else { return }
            Task { await self.handleIncomingConnection(connection) }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("SonosLocalClient: listener failed — \(error)")
            }
        }
        listener.start(queue: DispatchQueue(label: "sonos-event-listener"))

        // Give the listener a moment to bind and get assigned a port
        Thread.sleep(forTimeInterval: 0.1)
        let actualPort = listener.port?.rawValue ?? 0

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
                .replacingOccurrences(of: "&amp;", with: "&")

            let stateStr = SimpleXMLParser.extractValue(fromString: decoded, tag: "TransportState") ?? ""
            let state: PlaybackState
            switch stateStr {
            case "PLAYING": state = .playing
            case "PAUSED_PLAYBACK": state = .paused
            case "TRANSITIONING": state = .transitioning
            default: state = .stopped
            }

            let title = SimpleXMLParser.extractValue(fromString: decoded, tag: "dc:title")
            let artist = SimpleXMLParser.extractValue(fromString: decoded, tag: "dc:creator")
            let album = SimpleXMLParser.extractValue(fromString: decoded, tag: "upnp:album")

            var track: SonosTrack?
            if let title, !title.isEmpty {
                track = SonosTrack(title: title, artist: artist ?? "", album: album ?? "",
                                  albumArtURL: nil, duration: 0, position: 0)
            }

            let sid = extractHeaderValue(from: text, header: "SID") ?? ""
            let playerId = playerIdForSID(sid)
            if let playerId {
                onTransportEvent?(playerId, state, track)
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
