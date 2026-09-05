import Foundation

/// One way to fetch a track's audio. Mirrors `LibrarySource` /
/// `LibrarySourceKind` in the Omarchy backend (backend/library_handler.h).
public enum SourceKind: String, Codable, CaseIterable, Sendable {
    case local
    case ssh
    case https
    case network

    /// Label shown in the UI. Matches `method_name` (backend/app.c:816).
    public var displayName: String {
        switch self {
        case .local: return "Local file"
        case .ssh: return "SSH"
        case .https: return "HTTPS"
        case .network: return "Local network"
        }
    }
}

/// A single source entry. On disk the transport fields use SCREAMING keys
/// (`PATH`, `USERNAME`, `URL`, `IP`) and `kind` is lowercase — the exact shape
/// `library_handler.c` reads and writes, so libraries stay portable between the
/// macOS app and the Omarchy plugin.
public struct Source: Codable, Equatable, Hashable, Sendable {
    public var kind: SourceKind
    public var path: String?
    public var username: String?
    public var url: String?
    public var ip: String?

    public init(kind: SourceKind, path: String? = nil, username: String? = nil,
                url: String? = nil, ip: String? = nil) {
        self.kind = kind
        self.path = Source.trimmedOrNil(path)
        self.username = Source.trimmedOrNil(username)
        self.url = Source.trimmedOrNil(url)
        self.ip = Source.trimmedOrNil(ip)
    }

    private static func trimmedOrNil(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// True when every transport field the kind needs is present. Mirrors
    /// `source_is_complete` (backend/library_handler.c:406).
    public var isComplete: Bool {
        switch kind {
        case .local: return path?.isEmpty == false
        case .https: return url?.isEmpty == false
        case .ssh, .network:
            return path?.isEmpty == false && username?.isEmpty == false && ip?.isEmpty == false
        }
    }

    /// Stable identity for de-duplication when rebuilding the `*` playlist.
    /// Mirrors `source_key` (backend/app.c:1342).
    public var dedupKey: String {
        let unit = "\u{1f}"
        return [String(kindOrdinal), path ?? "", url ?? "", username ?? "", ip ?? ""]
            .joined(separator: unit)
    }

    /// Numeric order matching the C `LibrarySourceKind` enum, used by `dedupKey`.
    private var kindOrdinal: Int {
        switch kind {
        case .local: return 0
        case .ssh: return 1
        case .https: return 2
        case .network: return 3
        }
    }

    // MARK: Codable — SCREAMING transport keys, `null` for absent values.

    private enum CodingKeys: String, CodingKey {
        case kind
        case path = "PATH"
        case username = "USERNAME"
        case url = "URL"
        case ip = "IP"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(SourceKind.self, forKey: .kind)
        // Absent key and explicit JSON null both decode to nil.
        path = try c.decodeIfPresent(String.self, forKey: .path)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        ip = try c.decodeIfPresent(String.self, forKey: .ip)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        // The C writer always emits all four keys (null when unset); match it so
        // files diff cleanly between the two implementations.
        try encodeFieldOrNull(&c, path, forKey: .path)
        try encodeFieldOrNull(&c, username, forKey: .username)
        try encodeFieldOrNull(&c, url, forKey: .url)
        try encodeFieldOrNull(&c, ip, forKey: .ip)
    }

    private func encodeFieldOrNull(_ c: inout KeyedEncodingContainer<CodingKeys>,
                                   _ value: String?, forKey key: CodingKeys) throws {
        if let value { try c.encode(value, forKey: key) }
        else { try c.encodeNil(forKey: key) }
    }
}
