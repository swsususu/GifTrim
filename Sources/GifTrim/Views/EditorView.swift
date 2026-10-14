import AppKit
import AVFoundation
import GifTrimCore
import SwiftUI

struct EditorView: View {
    @Bindable var editor: EditorModel
    @State private var keyMonitor: Any?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                CanvasView(editor: editor)
                    .frame(minWidth: 520, minHeight: 300)
                Divider()
                TimelineView(editor: editor)
                    .frame(height: 132)
            }
            InspectorView(editor: editor)
                .frame(minWidth: 300, idealWidth: 320, maxWidth: 420)
        }
        .toolbar { EditorToolbar(editor: editor) }
        .navigationTitle(editor.source.displayName)
        .sheet(isPresented: $editor.showExport) {
            ExportView(editor: editor)
        }
        .onAppear { installKeyMonitor() }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    /// Single-key shortcuts that must not fire while the user is typing in a text field.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [editor] event in
            if let responder = event.window?.firstResponder, responder is NSText { return event }
            if event.window?.attachedSheet != nil || event.window?.isSheet == true { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
            guard mods.isEmpty else { return event }
            switch event.keyCode {
            case 49: editor.togglePlay(); return nil // space
            case 123: editor.step(-1); return nil // left
            case 124: editor.step(1); return nil // right
            default: break
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "i": editor.setTrimStartToCurrent(); return nil
            case "o": editor.setTrimEndToCurrent(); return nil
            default: return event
            }
        }
    }
}

struct EditorToolbar: ToolbarContent {
    @Bindable var editor: EditorModel
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.closeProject() } label: { Label("关闭", systemImage: "chevron.backward") }
                .help("关闭项目，回到开始页")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let est = editor.estimate {
                Text("约 \(formatBytes(est.bytes)) · \(est.frames) 帧")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .opacity(editor.isEstimating ? 0.5 : 1)
                    .help("根据中间一段帧实际编码后估算")
            } else if editor.isEstimating {
                ProgressView().controlSize(.small)
            }
            Button { editor.addText() } label: { Label("文字", systemImage: "character.textbox") }
                .labelStyle(.titleAndIcon)
                .help("添加文字")
            Button { editor.showExport = true } label: {
                Label("预览并导出", systemImage: "square.and.arrow.up")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.accentColor))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
                .help("生成 GIF 预览，然后保存 (⌘E)")
        }
    }
}

func formatBytes(_ bytes: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowedUnits = [.useKB, .useMB]
    return f.string(fromByteCount: bytes)
}

func formatTime(_ t: Double) -> String {
    let total = max(0, t)
    let m = Int(total) / 60
    let s = total - Double(m * 60)
    return String(format: "%d:%05.2f", m, s)
}
