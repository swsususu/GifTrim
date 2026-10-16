import AppKit
import GifTrimCore
import Observation
import UniformTypeIdentifiers

/// Top-level app state: the current editor (if any), loading/errors and recording entry points.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var editor: EditorModel?
    var isLoading = false
    var errorMessage: String?
    var showCamera = false

    let screenRecorder = ScreenRecorder()
    @ObservationIgnored private var openToken = 0

    init() {
        AppSettings.register()
        Self.removeStalePreviews()
    }

    /// Deletes preview GIFs left behind by earlier sessions (crash / force quit).
    private static func removeStalePreviews() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix("giftrim-preview-") && name.hasSuffix(".gif") {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    static var openableTypes: [UTType] { MediaSource.videoTypes + MediaSource.imageTypes }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.openableTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "选择一个视频、一个动图，或多张图片（按文件名排序成序列）"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        open(urls: panel.urls)
    }

    func open(urls: [URL]) {
        guard !urls.isEmpty else { return }
        openToken += 1
        let token = openToken
        isLoading = true
        Task {
            // Only the latest open may clear the loading state or publish a result.
            defer { if token == openToken { isLoading = false } }
            do {
                let source = try await MediaSource.open(urls: urls,
                                                        stillFrameDuration: AppSettings.stillFrameDuration)
                guard token == openToken else { return }
                editor?.teardown()
                editor = EditorModel(source: source)
                NSDocumentController.shared.noteNewRecentDocumentURL(urls[0])
                applyDebugState()
            } catch {
                if token == openToken { errorMessage = error.localizedDescription }
            }
        }
    }

    func closeProject() {
        editor?.teardown()
        editor = nil
    }

    /// Developer hook for UI screenshots: GIFTRIM_DEBUG_STATE=text|crop|export|frames|filter.
    private func applyDebugState() {
        guard let editor, let state = ProcessInfo.processInfo.environment["GIFTRIM_DEBUG_STATE"] else { return }
        switch state {
        case "text":
            editor.addText()
            editor.project.texts[0].text = "你好 GifTrim"
            editor.projectDidChange()
        case "crop":
            editor.inspectorTab = .crop
            editor.project.crop = NormalizedRect(x: 0.1, y: 0.1, width: 0.6, height: 0.7)
            editor.projectDidChange()
        case "export":
            editor.addText()
            editor.project.texts[0].text = "导出预览"
            editor.showExport = true
        case "frames":
            editor.inspectorTab = .frames
            editor.beginFrameEditing()
        case "filter":
            editor.inspectorTab = .filter
            editor.project.adjustments.effect = .sepia
            editor.projectDidChange()
        default: break
        }
    }

    func startScreenRecording() {
        screenRecorder.begin { [weak self] result in
            switch result {
            case .success(let url): self?.open(urls: [url])
            case .failure(let error):
                if case RecorderError.cancelled = error { return }
                self?.errorMessage = error.localizedDescription
            }
        }
    }
}

/// Persistent preferences (UserDefaults).
enum AppSettings {
    private static let d = UserDefaults.standard

    static func register() {
        d.register(defaults: [
            "defaultWidth": 480,
            "defaultFPS": 15.0,
            "defaultQuality": 90,
            "stillFrameDuration": 0.5,
            "recordShowCursor": true,
            "recordFPS": 30,
            "autoCheckUpdates": true,
        ])
    }

    static var defaultWidth: Int { d.integer(forKey: "defaultWidth") }
    static var defaultFPS: Double { d.double(forKey: "defaultFPS") }
    static var defaultQuality: Int { d.integer(forKey: "defaultQuality") }
    static var stillFrameDuration: Double { d.double(forKey: "stillFrameDuration") }
    static var recordShowCursor: Bool { d.bool(forKey: "recordShowCursor") }
    static var recordFPS: Int { d.integer(forKey: "recordFPS") }
    static var autoCheckUpdates: Bool { d.bool(forKey: "autoCheckUpdates") }

    /// Folder used for recordings (kept so users can re-open them).
    static var recordingsFolder: URL {
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("GifTrim", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func newRecordingURL(prefix: String) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return recordingsFolder.appendingPathComponent("\(prefix) \(f.string(from: Date())).mov")
    }
}
