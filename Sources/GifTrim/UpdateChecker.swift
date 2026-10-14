import AppKit
import GifTrimCore

/// Checks GitHub Releases for a newer version and can download + install it in place.
/// Like Trickle: a silent check at launch (if enabled) and a manual "检查更新…" menu item.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private static let latestURL = URL(string: "https://api.github.com/repos/swsususu/GifTrim/releases/latest")!
    private var busy = false

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Silent launch check: only speaks up when an update exists.
    func checkAtLaunch() {
        guard AppSettings.autoCheckUpdates,
              Bundle.main.bundleURL.pathExtension == "app",   // skip `swift run`
              !Self.currentVersion.contains("dev") else { return }
        Task {
            try? await Task.sleep(for: .seconds(5))
            await check(silent: true)
        }
    }

    func check(silent: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let release = try await fetchLatest()
            if let newer = release.newer(than: Self.currentVersion) {
                promptInstall(newer)
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

    private func promptInstall(_ release: ReleaseInfo) {
        let a = NSAlert()
        a.messageText = "发现新版本 \(release.version?.description ?? release.tagName)"
        var info = "当前版本 \(Self.currentVersion)。"
        if let body = release.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            info += "\n\n" + String(body.prefix(800))
        }
        a.informativeText = info
        let canInstall = release.dmgURL != nil
        if canInstall { a.addButton(withTitle: "下载并安装") }
        a.addButton(withTitle: "查看发布页")
        a.addButton(withTitle: "以后再说")
        NSApp.activate(ignoringOtherApps: true)
        switch (a.runModal(), canInstall) {
        case (.alertFirstButtonReturn, true):
            Task { await install(release) }
        case (.alertFirstButtonReturn, false), (.alertSecondButtonReturn, true):
            NSWorkspace.shared.open(release.htmlURL)
        default: break
        }
    }

    // MARK: - Install

    private func install(_ release: ReleaseInfo) async {
        guard let dmgURL = release.dmgURL else { return }
        let target = Bundle.main.bundleURL
        do {
            let (tmp, _) = try await URLSession.shared.download(from: dmgURL)
            let dmg = FileManager.default.temporaryDirectory
                .appendingPathComponent("GifTrim-update-\(UUID().uuidString).dmg")
            try FileManager.default.moveItem(at: tmp, to: dmg)

            guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                // Can't replace in place (e.g. no write access): hand the DMG to Finder.
                NSWorkspace.shared.open(dmg)
                return
            }
            let staged = try await Task.detached { try Self.stage(dmg: dmg) }.value
            try relaunch(replacing: target, with: staged)
        } catch {
            alert("更新失败", error.localizedDescription + "\n\n可以到发布页手动下载。")
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    /// Mounts the DMG, copies GifTrim.app out to a temp folder and detaches.
    nonisolated private static func stage(dmg: URL) throws -> URL {
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
        try run("/usr/bin/ditto", [src.path, staged.path])
        try run("/usr/bin/codesign", ["--verify", "--strict", staged.path])
        return staged
    }

    /// Waits for this process to quit, swaps the bundle and opens the new one.
    private func relaunch(replacing target: URL, with staged: URL) throws {
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2" && /usr/bin/ditto "$3" "$2" && /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
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
