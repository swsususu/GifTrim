import AppKit
import CryptoKit
import GifTrimCore

/// Checks GitHub Releases for a newer version and can download + install it in place.
/// Like Trickle: a silent check at launch (if enabled) and a manual "检查更新…" menu item.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private static let latestURL = URL(string: "https://api.github.com/repos/swsususu/GifTrim/releases/latest")!
    private var busy = false

    private static var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Silent launch check: only speaks up when an update exists.
    func checkAtLaunch() {
        guard AppSettings.autoCheckUpdates,
              Self.isAppBundle,   // skip `swift run`
              !Self.currentVersion.contains("dev") else { return }
        Task {
            try? await Task.sleep(for: .seconds(5))
            await check(silent: true)
        }
    }

    func check(silent: Bool) async {
        guard !busy else { return }
        busy = true
        var installing = false   // install() takes over the busy flag
        defer { if !installing { busy = false } }
        do {
            let release = try await fetchLatest()
            if let newer = release.newer(than: Self.currentVersion) {
                installing = promptInstall(newer)
            } else if !silent {
                alert("已是最新版本", "当前版本 \(Self.currentVersion) 就是最新版。")
            }
        } catch {
            if !silent { alert("检查更新失败", error.localizedDescription) }
        }
    }

    private func fetchLatest() async throws -> ReleaseInfo {
        var req = URLRequest(url: Self.latestURL, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("GifTrim/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("GitHub 返回 HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(ReleaseInfo.self, from: data)
    }

    /// Returns true when an install was started (it then owns the busy flag).
    private func promptInstall(_ release: ReleaseInfo) -> Bool {
        let a = NSAlert()
        a.messageText = "发现新版本 \(release.version?.description ?? release.tagName)"
        var info = "当前版本 \(Self.currentVersion)。"
        if let body = release.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            info += "\n\n" + String(body.prefix(800))
        }
        a.informativeText = info
        let canInstall = release.dmgURL != nil && Self.isAppBundle
        if canInstall { a.addButton(withTitle: "下载并安装") }
        a.addButton(withTitle: "查看发布页")
        a.addButton(withTitle: "以后再说")
        NSApp.activate(ignoringOtherApps: true)
        switch (a.runModal(), canInstall) {
        case (.alertFirstButtonReturn, true):
            Task { await install(release) }
            return true
        case (.alertFirstButtonReturn, false), (.alertSecondButtonReturn, true):
            NSWorkspace.shared.open(release.htmlURL)
        default: break
        }
        return false
    }

    // MARK: - Install

    private func install(_ release: ReleaseInfo) async {
        defer { busy = false }
        guard Self.isAppBundle, let dmgURL = release.dmgURL else { return }   // never replace a `swift run` build
        let target = Bundle.main.bundleURL
        let (current, bundleID) = (Self.currentVersion, Bundle.main.bundleIdentifier)
        do {
            let (tmp, resp) = try await URLSession.shared.download(from: dmgURL)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                try? FileManager.default.removeItem(at: tmp)
                throw UpdateError("下载失败：HTTP \(http.statusCode)")
            }
            let dmg = FileManager.default.temporaryDirectory
                .appendingPathComponent("GifTrim-update-\(UUID().uuidString).dmg")
            try FileManager.default.moveItem(at: tmp, to: dmg)

            // Releases may ship `<dmg name>.sha256`; verify it when present.
            if let shaURL = release.sha256URL {
                do {
                    try await verifyChecksum(of: dmg, against: shaURL)
                } catch {
                    try? FileManager.default.removeItem(at: dmg)
                    throw error
                }
            }

            guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                // Can't replace in place (e.g. no write access): hand the DMG to Finder.
                NSWorkspace.shared.open(dmg)
                return
            }
            let staged = try await Task.detached {
                try Self.stage(dmg: dmg, expectedBundleID: bundleID, currentVersion: current)
            }.value
            try relaunch(replacing: target, with: staged)
        } catch {
            alert("更新失败", error.localizedDescription + "\n\n可以到发布页手动下载。")
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    private func verifyChecksum(of file: URL, against shaURL: URL) async throws {
        let (data, resp) = try await URLSession.shared.data(from: shaURL)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("校验文件下载失败：HTTP \(http.statusCode)")
        }
        // Format: "<hex>  <name>" (shasum) or just "<hex>".
        let expected = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isWhitespace }).first.map { $0.lowercased() } ?? ""
        let actual = try await Task.detached { try Self.sha256(of: file) }.value
        guard actual == expected else { throw UpdateError("安装包校验失败（SHA-256 不匹配）") }
    }

    nonisolated private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Mounts the DMG, copies GifTrim.app out to a temp folder and detaches.
    nonisolated private static func stage(dmg: URL, expectedBundleID: String?, currentVersion: String) throws -> URL {
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("GifTrim-mnt-\(UUID().uuidString)")
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? FileManager.default.removeItem(at: dmg)
        }
        let src = mount.appendingPathComponent("GifTrim.app")
        guard FileManager.default.fileExists(atPath: src.path) else { throw UpdateError("安装包里没有 GifTrim.app") }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GifTrim-new-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staged = dir.appendingPathComponent("GifTrim.app")
        do {
            try run("/usr/bin/ditto", [src.path, staged.path])
            try run("/usr/bin/codesign", ["--verify", "--strict", staged.path])
            let info = Bundle(url: staged)?.infoDictionary
            guard let id = info?["CFBundleIdentifier"] as? String, id == expectedBundleID else {
                throw UpdateError("安装包的应用标识与当前应用不一致")
            }
            guard let v = (info?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init),
                  let cur = AppVersion(currentVersion), cur < v else {
                throw UpdateError("安装包版本不比当前版本新")
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return staged
    }

    /// Waits for this process to quit, swaps the bundle and opens the new one.
    private func relaunch(replacing target: URL, with staged: URL) throws {
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2.new" "$2.old"
        if /usr/bin/ditto "$3" "$2.new" && mv "$2" "$2.old"; then
          if mv "$2.new" "$2"; then
            rm -rf "$2.old"
          else
            mv "$2.old" "$2"
          fi
        fi
        rm -rf "$2.new"
        /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
        rm -rf "$(dirname "$3")"
        /usr/bin/open "$2"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier),
                       target.path, staged.path]
        try p.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) 失败（\(p.terminationStatus)）")
        }
        return p.terminationStatus
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
