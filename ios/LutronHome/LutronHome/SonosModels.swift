import Foundation

extension String {
    /// Decode common XML/HTML entities that leak through UPnP DIDL-Lite parsing.
    var xmlDecoded: String {
        self.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#x26;", with: "&")
    }
}

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
    var uri: String?       // local playback URI (from ContentDirectory FV:2)
    var metadata: String?  // DIDL-Lite metadata for SetAVTransportURI
}

// MARK: - Music Services & Content Browsing

struct SonosMusicService: Identifiable {
    let id: Int          // ServiceType number (e.g. 2311 = Spotify)
    let name: String
    let containerID: String  // Root ObjectID for ContentDirectory Browse
}

struct SonosContentItem: Identifiable {
    let id: String       // ObjectID
    let parentID: String
    let title: String
    let artist: String
    let album: String
    let albumArtURI: String
    let isContainer: Bool
    let uri: String      // res URI for playable items
    let metadata: String // DIDL-Lite metadata for SetAVTransportURI
}

// MARK: - Group Presets

struct SonosGroupPreset: Identifiable, Codable, Equatable {
    let id: String           // UUID string
    var name: String         // e.g. "Main Floor"
    var playerIds: [String]  // UUIDs of the speakers in this preset
}

// MARK: - Topology Cache

struct SonosTopologyCache: Codable {
    var players: [SonosPlayer]
    var lastUpdated: Date
}
