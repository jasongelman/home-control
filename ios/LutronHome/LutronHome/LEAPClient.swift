import Foundation
import Network
@preconcurrency import Dispatch

/// Low-level LEAP protocol client using NWConnection with TLS + mTLS.
/// LEAP sends newline-delimited JSON over TLS on port 8081.
class LEAPClient: @unchecked Sendable {
    private var connection: NWConnection?
    private var dataBuffer = Data()
    private var tagCounter = 0
    private var pending: [String: (Result<LEAPMessage, Error>) -> Void] = [:]
    private var pendingTimers: [String: DispatchWorkItem] = [:]
    private let queue = DispatchQueue(label: "com.lutron.leap", qos: .userInitiated)

    var onMessage: ((LEAPMessage) -> Void)?
    var onRawMessage: ((String) -> Void)?
    var onConnect: (() -> Void)?
    var onDisconnect: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    private let host: String
    private let port: UInt16
    private let identity: SecIdentity?
    private let caCert: SecCertificate?

    init(host: String, port: UInt16 = 8081, identity: SecIdentity?, caCert: SecCertificate?) {
        self.host = host
        self.port = port
        self.identity = identity
        self.caCert = caCert
    }

    // MARK: - Connection

    func connect() {
        let tlsOptions = NWProtocolTLS.Options()
        let secOptions = tlsOptions.securityProtocolOptions

        // Client certificate for mTLS
        if let identity {
            sec_protocol_options_set_local_identity(secOptions,
                sec_identity_create(identity)!)
        }

        // Accept self-signed server certs (Lutron uses self-signed)
        sec_protocol_options_set_verify_block(secOptions, { _, trust, completionHandler in
            completionHandler(true) // Trust all — processor uses self-signed cert
        }, queue)

        let params = NWParameters(tls: tlsOptions)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            print("LEAP connection state: \(state)")
            switch state {
            case .ready:
                self.startReceiving()
                DispatchQueue.main.async { self.onConnect?() }
            case .failed(let err):
                DispatchQueue.main.async { self.onError?(err) }
                self.cleanup(reason: err.localizedDescription)
            case .cancelled:
                self.cleanup(reason: "cancelled")
            case .waiting(let err):
                print("LEAP connection waiting: \(err)")
            default:
                break
            }
        }

        self.connection = conn
        conn.start(queue: queue)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        rejectAllPending(error: LEAPError.disconnected)
    }

    var isConnected: Bool {
        connection?.state == .ready
    }

    // MARK: - Sending

    /// Send a tagged request and wait for the matching response.
    func send(_ msg: LEAPMessagePayload, timeout: TimeInterval = 15) async throws -> LEAPMessage {
        tagCounter += 1
        let tag = String(tagCounter)
        var fullMsg = msg
        fullMsg.Header.ClientTag = tag

        return try await withCheckedThrowingContinuation { continuation in
            let timer = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Run timeout handling on our serial queue to avoid data races
                self.queue.async {
                    guard self.pending.removeValue(forKey: tag) != nil else { return } // already handled
                    self.pendingTimers.removeValue(forKey: tag)
                    print("LEAP: TIMEOUT for tag \(tag) url \(msg.Header.Url)")
                    continuation.resume(throwing: LEAPError.timeout(url: msg.Header.Url))
                }
            }

            queue.async { [weak self] in
                guard let self else { return }
                self.pending[tag] = { result in
                    timer.cancel()
                    self.pendingTimers.removeValue(forKey: tag)
                    continuation.resume(with: result)
                }
                self.pendingTimers[tag] = timer
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                self.write(fullMsg)
            }
        }
    }

    // MARK: - Receiving

    private func startReceiving() {
        guard let conn = connection else {
            print("LEAP startReceiving: no connection!")
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.dataBuffer.append(data)
                self.processBuffer()
            }
            if isComplete || error != nil {
                let reason = error?.localizedDescription ?? "connection closed"
                self.cleanup(reason: reason)
                return
            }
            self.startReceiving()
        }
    }

    private static let newlineByte: UInt8 = 0x0A // \n

    private func processBuffer() {
        // Process all complete newline-delimited lines in the buffer
        while let newlineIndex = dataBuffer.firstIndex(of: Self.newlineByte) {
            let lineData = dataBuffer.subdata(in: dataBuffer.startIndex..<newlineIndex)
            dataBuffer = dataBuffer.subdata(in: dataBuffer.index(after: newlineIndex)..<dataBuffer.endIndex)

            // Skip empty lines
            if lineData.isEmpty { continue }

            // Trim trailing \r if present
            let trimmedData: Data
            if lineData.last == 0x0D { // \r
                trimmedData = lineData.dropLast()
            } else {
                trimmedData = lineData
            }

            if trimmedData.isEmpty { continue }

            // Log message for debugging (abbreviated)
            if trimmedData.count < 500, let preview = String(data: trimmedData, encoding: .utf8) {
                print("LEAP RX: \(preview)")
            } else {
                let preview = String(data: trimmedData.prefix(150), encoding: .utf8) ?? "?"
                print("LEAP RX (\(trimmedData.count) bytes): \(preview)...")
            }

            do {
                let msg = try JSONDecoder().decode(LEAPMessage.self, from: trimmedData)
                dispatch(msg)
            } catch {
                print("LEAP: JSON decode error: \(error)")
                // Try to at least extract the ClientTag to unblock pending requests
                if let rawDict = try? JSONSerialization.jsonObject(with: trimmedData) as? [String: Any],
                   let header = rawDict["Header"] as? [String: Any],
                   let tag = header["ClientTag"] as? String,
                   let handler = pending.removeValue(forKey: tag) {
                    let url = header["Url"] as? String ?? ""
                    let statusCode = header["StatusCode"] as? String
                    let msgType = header["MessageBodyType"] as? String
                    let minMsg = LEAPMessage(
                        CommuniqueType: rawDict["CommuniqueType"] as? String,
                        Header: LEAPMessageHeader(
                            ClientTag: tag,
                            MessageBodyType: msgType,
                            StatusCode: statusCode,
                            Url: url
                        ),
                        Body: nil
                    )
                    handler(.success(minMsg))
                }
            }
        }
    }

    private func dispatch(_ msg: LEAPMessage) {
        let tag = msg.Header.ClientTag ?? "none"
        print("LEAP dispatch: tag=\(tag) url=\(msg.Header.Url) status=\(msg.Header.StatusCode ?? "nil") bodyType=\(msg.Header.MessageBodyType ?? "nil")")

        if let tag = msg.Header.ClientTag, let handler = pending.removeValue(forKey: tag) {
            handler(.success(msg))
        } else {
            // Unsolicited (subscription updates)
            DispatchQueue.main.async { self.onMessage?(msg) }
        }
    }

    // MARK: - Writing

    private func write(_ msg: LEAPMessagePayload) {
        guard let conn = connection else {
            print("LEAP write: no connection")
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(msg) else {
            print("LEAP write: encode failed")
            return
        }
        var payload = data
        payload.append(contentsOf: "\r\n".utf8)
        let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? "?"
        print("LEAP TX: \(preview)")
        conn.send(content: payload, completion: .contentProcessed { error in
            if let error {
                print("LEAP write error: \(error)")
            }
        })
    }

    // MARK: - Helpers

    private func cleanup(reason: String) {
        rejectAllPending(error: LEAPError.disconnected)
        DispatchQueue.main.async { self.onDisconnect?(reason) }
    }

    private func rejectAllPending(error: Error) {
        for (_, handler) in pending {
            handler(.failure(error))
        }
        pending.removeAll()
        for (_, timer) in pendingTimers {
            timer.cancel()
        }
        pendingTimers.removeAll()
    }
}

// MARK: - Types

enum LEAPError: Error, LocalizedError {
    case disconnected
    case timeout(url: String)
    case loginFailed(status: String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .disconnected: return "Disconnected from processor"
        case .timeout(let url): return "Timeout waiting for \(url)"
        case .loginFailed(let s): return "Login failed: \(s)"
        case .notConnected: return "Not connected"
        }
    }
}

struct LEAPMessageHeader: Codable {
    var ClientTag: String?
    var MessageBodyType: String?
    var StatusCode: String?
    var Url: String
    var RequestType: String?
}

struct LEAPMessage: Codable {
    var CommuniqueType: String?
    var Header: LEAPMessageHeader
    var Body: LEAPBody?
}

struct LEAPMessagePayload: Encodable {
    var CommuniqueType: String
    var Header: LEAPMessageHeader
    var Body: LEAPBodyPayload?
}

// Flexible body decoding — use AnyCodable dict for everything
struct LEAPBody: Codable {
    // Capture all known body keys
    var Areas: [[String: AnyCodable]]?
    var Zones: [[String: AnyCodable]]?
    var Zone: [String: AnyCodable]?
    var ZoneStatuses: [[String: AnyCodable]]?
    var ZoneStatus: [String: AnyCodable]?
    var VirtualButtons: [[String: AnyCodable]]?
    var Login: [String: AnyCodable]?
    var Server: [String: AnyCodable]?

    // Catch anything else we don't explicitly model (ControlStations, ButtonGroups, Buttons, Device, LEDStatus, etc.)
    var additionalValues: [String: AnyCodable]?

    struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
    }

    enum CodingKeys: String, CodingKey {
        case Areas, Zones, Zone, ZoneStatuses, ZoneStatus, VirtualButtons, Login, Server
    }

    private static let knownKeys: Set<String> = [
        "Areas", "Zones", "Zone", "ZoneStatuses", "ZoneStatus", "VirtualButtons", "Login", "Server"
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        Areas = try container.decodeIfPresent([[String: AnyCodable]].self, forKey: .Areas)
        Zones = try container.decodeIfPresent([[String: AnyCodable]].self, forKey: .Zones)
        Zone = try container.decodeIfPresent([String: AnyCodable].self, forKey: .Zone)
        ZoneStatuses = try container.decodeIfPresent([[String: AnyCodable]].self, forKey: .ZoneStatuses)
        ZoneStatus = try container.decodeIfPresent([String: AnyCodable].self, forKey: .ZoneStatus)
        VirtualButtons = try container.decodeIfPresent([[String: AnyCodable]].self, forKey: .VirtualButtons)
        Login = try container.decodeIfPresent([String: AnyCodable].self, forKey: .Login)
        Server = try container.decodeIfPresent([String: AnyCodable].self, forKey: .Server)

        // Decode any keys not in CodingKeys into additionalValues
        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        var extras: [String: AnyCodable] = [:]
        for key in dynamicContainer.allKeys where !Self.knownKeys.contains(key.stringValue) {
            if let val = try? dynamicContainer.decode(AnyCodable.self, forKey: key) {
                extras[key.stringValue] = val
            }
        }
        additionalValues = extras.isEmpty ? nil : extras
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(Areas, forKey: .Areas)
        try container.encodeIfPresent(Zones, forKey: .Zones)
        try container.encodeIfPresent(Zone, forKey: .Zone)
        try container.encodeIfPresent(ZoneStatuses, forKey: .ZoneStatuses)
        try container.encodeIfPresent(ZoneStatus, forKey: .ZoneStatus)
        try container.encodeIfPresent(VirtualButtons, forKey: .VirtualButtons)
        try container.encodeIfPresent(Login, forKey: .Login)
        try container.encodeIfPresent(Server, forKey: .Server)
    }
}

struct LEAPBodyPayload: Encodable {
    var Command: LEAPCommand?
    var Login: LEAPLogin?
    var LEDStatus: LEAPLEDStatus?
}

struct LEAPLEDStatus: Encodable {
    var State: String  // "On" or "Off"
}

struct LEAPCommand: Encodable {
    var CommandType: String
    var Parameter: [[String: AnyCodable]]?
    var FadeTime: String?
    /// For GoToSpectrumTuningLevel (full RGB color). Nested shape:
    /// { Level, ColorTuningStatus: { HSVTuningLevel: { Hue, Saturation } } }
    var SpectrumTuningLevelParameters: [String: AnyCodable]?
}

struct LEAPLogin: Encodable {
    var ContextType: String = "Application"
    var LoginId: String
    var Password: String
}

// AnyCodable for flexible JSON
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { value = v }
        else if let v = try? container.decode(Int.self) { value = v }
        else if let v = try? container.decode(Double.self) { value = v }
        else if let v = try? container.decode(String.self) { value = v }
        else if let v = try? container.decode([String: AnyCodable].self) { value = v }
        else if let v = try? container.decode([AnyCodable].self) { value = v }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let v = value as? Bool { try container.encode(v) }
        else if let v = value as? Int { try container.encode(v) }
        else if let v = value as? Double { try container.encode(v) }
        else if let v = value as? String { try container.encode(v) }
        else if let v = value as? [String: AnyCodable] { try container.encode(v) }
        else if let v = value as? [AnyCodable] { try container.encode(v) }
        else { try container.encodeNil() }
    }

    var stringValue: String? { value as? String }
    var intValue: Int? {
        if let v = value as? Int { return v }
        if let v = value as? Double { return Int(v) }
        return nil
    }
    var doubleValue: Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        return nil
    }
    var boolValue: Bool? { value as? Bool }
    var dictValue: [String: AnyCodable]? { value as? [String: AnyCodable] }
    var arrayValue: [AnyCodable]? { value as? [AnyCodable] }
}

// MARK: - Certificate Loading

enum CertificateLoader {
    /// Read p12 password from Keychain or bundled secrets.json
    private static func loadPassword() -> String {
        // Try Keychain first (persisted from previous run or bundled secrets.json)
        if let pwd = KeychainHelper.loadString(for: "p12_password"), !pwd.isEmpty {
            return pwd
        }
        // Fallback: check app bundle for secrets.json
        if let bundleURL = Bundle.main.url(forResource: "secrets", withExtension: "json"),
           let data = try? Data(contentsOf: bundleURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let pwd = json["p12Password"] {
            // Cache in Keychain for next time
            KeychainHelper.save(pwd, for: "p12_password")
            return pwd
        }
        return ""
    }

    /// Load PKCS12 from bundle and extract identity + CA cert
    static func loadFromBundle(resource: String = "lutron_client") -> (identity: SecIdentity, ca: SecCertificate?)? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "p12"),
              let data = try? Data(contentsOf: url) else {
            print("CertLoader: couldn't find \(resource).p12 in bundle")
            return nil
        }

        let password = loadPassword()
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess, let items = rawItems as? [[String: Any]], let first = items.first else {
            print("CertLoader: PKCS12 import failed: \(status)")
            return nil
        }

        let identityValue = first[kSecImportItemIdentity as String]
        guard let identity = (identityValue as! SecIdentity?) else {
            print("CertLoader: no identity in PKCS12")
            return nil
        }

        // Extract CA cert from the chain
        let chain = first[kSecImportItemCertChain as String] as? [SecCertificate]
        let caCert = chain?.count ?? 0 > 1 ? chain?[1] : nil

        return (identity: identity, ca: caCert)
    }
}
