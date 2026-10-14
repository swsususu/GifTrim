import Foundation

/// Dotted numeric version ("v0.1.2", "0.2.0-beta" → [0, 2, 0]). Pre-release suffixes are ignored.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let core = s.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? ""
        let nums = core.split(separator: ".").map { Int($0) }
        guard !nums.isEmpty, !nums.contains(where: { $0 == nil }) else { return nil }
        parts = nums.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// The subset of GitHub's `releases/latest` response the app needs.
public struct ReleaseInfo: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    public let tagName: String
    public let htmlURL: URL
    public let body: String?
    public let draft: Bool?
    public let prerelease: Bool?
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body, draft, prerelease, assets
    }

    public var version: AppVersion? { AppVersion(tagName) }

    /// First `.dmg` asset, if the release has one.
    public var dmgURL: URL? { assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.browserDownloadURL }

    /// Returns the release when it is a published, newer version than `current`.
    public func newer(than current: String) -> ReleaseInfo? {
        guard draft != true, prerelease != true,
              let latest = version, let installed = AppVersion(current), installed < latest else { return nil }
        return self
    }
}
