import Foundation
import Testing
@testable import GifTrimCore

@Suite struct UpdateCheckTests {
    @Test func versionOrdering() {
        #expect(AppVersion("v0.1.0")! < AppVersion("0.1.1")!)
        #expect(AppVersion("0.9.9")! < AppVersion("0.10.0")!)
        #expect(AppVersion("1.0")! == AppVersion("v1.0.0")!)
        #expect(AppVersion("0.2.0-beta")!.description == "0.2.0-beta")
        #expect(AppVersion("0.2.0-beta")! < AppVersion("0.2.0")!)
        #expect(AppVersion("0.2.0-beta")! < AppVersion("0.2.0-rc.1")!)
        #expect(AppVersion("0.1.9")! < AppVersion("0.2.0-beta")!)
        #expect(AppVersion("0.1.10")! > AppVersion("0.1.9")!)
        #expect(AppVersion("0.2.0+5")! == AppVersion("0.2.0")!)
        #expect(AppVersion("dev") == nil)
    }

    @Test func decodesGitHubRelease() throws {
        let json = """
        {"tag_name":"v0.2.0","html_url":"https://github.com/swsususu/GifTrim/releases/tag/v0.2.0",
         "body":"notes","draft":false,"prerelease":false,
         "assets":[{"name":"GifTrim_0.2.0_universal.dmg",
                    "browser_download_url":"https://example.com/GifTrim_0.2.0_universal.dmg"}]}
        """
        let r = try JSONDecoder().decode(ReleaseInfo.self, from: Data(json.utf8))
        #expect(r.dmgURL?.lastPathComponent == "GifTrim_0.2.0_universal.dmg")
        #expect(r.newer(than: "0.1.0") != nil)
        #expect(r.newer(than: "0.2.0") == nil)
        #expect(r.newer(than: "0.3.0") == nil)
        #expect(r.newer(than: "0.0.0-dev") != nil)
        #expect(r.newer(than: "0.2.0-beta") != nil)
    }

    @Test func picksNamedDmgAndChecksum() throws {
        let json = """
        {"tag_name":"v0.2.0","html_url":"https://example.com/r","assets":[
         {"name":"other.dmg","browser_download_url":"https://example.com/other.dmg"},
         {"name":"GifTrim_0.2.0_universal.dmg","browser_download_url":"https://example.com/GifTrim_0.2.0_universal.dmg"},
         {"name":"GifTrim_0.2.0_universal.dmg.sha256","browser_download_url":"https://example.com/GifTrim_0.2.0_universal.dmg.sha256"}]}
        """
        let r = try JSONDecoder().decode(ReleaseInfo.self, from: Data(json.utf8))
        #expect(r.dmgURL?.lastPathComponent == "GifTrim_0.2.0_universal.dmg")
        #expect(r.sha256URL?.lastPathComponent == "GifTrim_0.2.0_universal.dmg.sha256")
    }
}
