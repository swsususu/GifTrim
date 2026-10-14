import AppKit
import GifTrimCore
import SwiftUI
import UniformTypeIdentifiers

/// Encodes the real GIF to a temp file, plays it back, then saves (copies) it.
struct ExportView: View {
    let editor: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var progress: ExportProgress?
    @State private var result: ExportResult?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var savedURL: URL?

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("预览").font(.title3.bold())
                Spacer()
                if let result {
                    Text("\(Int(result.size.width))×\(Int(result.size.height)) · \(result.frameCount) 帧 · \(String(format: "%.2f", result.duration)) 秒 · \(formatBytes(result.fileSize))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            ZStack {
                Checkerboard()
                if let result {
                    AnimatedGIFView(url: result.url)
                        .frame(width: displaySize(result.size).width, height: displaySize(result.size).height)
                } else if let error {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                        Text(error).multilineTextAlignment(.center)
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack(spacing: 10) {
                        ProgressView(value: progress?.fraction ?? 0)
                            .frame(width: 260)
                        Text(progressText).font(.callout.monospacedDigit())
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(width: 640, height: 420)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if let savedURL {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("已保存到 \(savedURL.path)").lineLimit(1).truncationMode(.middle)
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
                        .buttonStyle(.link)
                }
                .font(.callout)
            }

            HStack {
                Button("取消") { cancelAndClose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("拷贝") { copyToPasteboard() }
                    .disabled(result == nil)
                    .help("拷贝 GIF 文件到剪贴板，可直接粘贴到聊天软件")
                Button("存储…") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(result == nil)
            }
        }
        .padding(20)
        .onAppear { start() }
        .onDisappear { task?.cancel() }
    }

    private var progressText: String {
        guard let p = progress else { return "准备中…" }
        return "正在生成 \(Int(p.fraction * 100))%  （渲染 \(p.rendered)/\(p.total) · 编码 \(p.encoded)/\(p.total)）"
    }

    private func displaySize(_ s: CGSize) -> CGSize {
        let r = aspectFit(s, in: CGRect(x: 0, y: 0, width: 640, height: 420))
        // Never upscale beyond 1:1 so the preview shows real pixels.
        if s.width <= 640 && s.height <= 420 { return s }
        return r.size
    }

    private func start() {
        editor.pause()
        let project = editor.project
        let source = editor.source
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("giftrim-preview-\(UUID().uuidString).gif")
        task = Task {
            do {
                let r = try await Exporter.export(project: project, source: source, to: tmp) { p in
                    Task { @MainActor in progress = p }
                }
                if Task.isCancelled { try? FileManager.default.removeItem(at: tmp); return }
                result = r
            } catch GifTrimError.cancelled {
                // closed
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func cancelAndClose() {
        task?.cancel()
        if let result { try? FileManager.default.removeItem(at: result.url) }
        dismiss()
    }

    private func save() {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.canCreateDirectories = true
        let base = editor.source.url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = base + ".gif"
        panel.directoryURL = UserDefaults.standard.url(forKey: "lastSaveDir") ?? editor.source.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: result.url, to: url)
            UserDefaults.standard.set(url.deletingLastPathComponent(), forKey: "lastSaveDir")
            savedURL = url
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func copyToPasteboard() {
        guard let result, let data = try? Data(contentsOf: result.url) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
        item.setString(result.url.absoluteString, forType: .fileURL)
        pb.writeObjects([item])
    }
}

/// NSImageView animates GIFs natively.
struct AnimatedGIFView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.animates = true
        v.imageScaling = .scaleProportionallyUpOrDown
        v.canDrawSubviewsIntoLayer = true
        v.image = NSImage(contentsOf: url)
        return v
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {}
}

struct SettingsView: View {
    @AppStorage("defaultWidth") private var defaultWidth = 480
    @AppStorage("defaultFPS") private var defaultFPS = 15.0
    @AppStorage("defaultQuality") private var defaultQuality = 90
    @AppStorage("stillFrameDuration") private var stillFrameDuration = 0.5
    @AppStorage("recordShowCursor") private var recordShowCursor = true
    @AppStorage("recordFPS") private var recordFPS = 30
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true

    var body: some View {
        Form {
            Section("新项目默认值") {
                Stepper("宽度：\(defaultWidth) px", value: $defaultWidth, in: 64...2000, step: 16)
                Stepper("帧率：\(Int(defaultFPS)) fps", value: $defaultFPS, in: 1...50, step: 1)
                Stepper("画质：\(defaultQuality)", value: $defaultQuality, in: 1...100)
                Stepper("图片序列每张时长：\(String(format: "%.2f", stillFrameDuration)) 秒",
                        value: $stillFrameDuration, in: 0.02...5, step: 0.05)
            }
            Section("录屏") {
                Toggle("录制鼠标指针", isOn: $recordShowCursor)
                Picker("录制帧率", selection: $recordFPS) {
                    Text("15 fps").tag(15)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                LabeledContent("录像保存位置") {
                    Button("在访达中打开") { NSWorkspace.shared.open(AppSettings.recordingsFolder) }
                }
            }
            Section("更新") {
                Toggle("启动时自动检查更新", isOn: $autoCheckUpdates)
                LabeledContent("当前版本 \(UpdateChecker.currentVersion)") {
                    Button("检查更新") { Task { await UpdateChecker.shared.check(silent: false) } }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding(.vertical, 8)
    }
}
