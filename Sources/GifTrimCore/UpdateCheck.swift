import Foundation

/// Dotted numeric version with an optional pre-release suffix ("v0.1.2", "0.2.0-beta" → [0, 2, 0] + "beta").
/// For equal numeric parts a version with a suffix sorts before the same version without one.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]
    public let suffix: String

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }   // build metadata is ignored
        var core = s
        var suffix = ""
        if let dash = s.firstIndex(of: "-") {
            core = String(s[..<dash])
            suffix = String(s[s.index(after: dash)...])
        }
        let nums = core.split(separator: ".").map { Int($0) }
        guard !nums.isEmpty, !nums.contains(where: { $0 == nil }) else { return nil }
        parts = nums.compactMap { $0 }
        self.suffix = suffix
    }

    public var description: String {
        let core = parts.map(String.init).joined(separator: ".")
        return suffix.isEmpty ? core : core + "-" + suffix
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        if a.suffix.isEmpty != b.suffix.isEmpty { return !a.suffix.isEmpty }   // pre-release < release
        return a.suffix.compare(b.suffix, options: .numeric) == .orderedAscending
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

    /// The installer asset: first `GifTrim*.dmg`, if the release has one.
    public var dmgAsset: Asset? {
        assets.first {
            let n = $0.name.lowercased()
            return n.hasPrefix("giftrim") && n.hasSuffix(".dmg")
        }
    }

    public var dmgURL: URL? { dmgAsset?.browserDownloadURL }

    /// Optional `<dmg name>.sha256` checksum asset.
    public var sha256URL: URL? {
        guard let dmg = dmgAsset else { return nil }
        return assets.first { $0.name == dmg.name + ".sha256" }?.browserDownloadURL
    }

    /// Returns the release when it is a published, newer version than `current`.
    public func newer(than current: String) -> ReleaseInfo? {
        guard draft != true, prerelease != true,
              let latest = version, let installed = AppVersion(current), installed < latest else { return nil }
        return self
    }
}
