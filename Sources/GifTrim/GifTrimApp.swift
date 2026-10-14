import AppKit
import GifTrimCore
import SwiftUI

@main
struct GifTrimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("GifTrim", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开…") { model.showOpenPanel() }
                    .keyboardShortcut("o")
                Divider()
                Button("录制屏幕…") { model.startScreenRecording() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("录制摄像头 / iPhone…") { model.showCamera = true }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Divider()
                Button("关闭项目") { model.closeProject() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(model.editor == nil)
            }
            CommandGroup(after: .appSettings) {
                Button("安装命令行工具 giftrim…") { CLIInstaller.install() }
                Button("为 AI 助手配置 MCP…") { CLIInstaller.copyMCPConfig() }
            }
            CommandGroup(replacing: .help) {
                Button("GifTrim 使用说明") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/swsususu/GifTrim#readme")!)
                }
                Button("AI / MCP 接入指南") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/swsususu/GifTrim/blob/main/docs/AI.md")!)
                }
                Button("反馈问题") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/swsususu/GifTrim/issues")!)
                }
            }
            CommandGroup(replacing: .saveItem) {
                Button("导出 GIF…") { model.editor?.showExport = true }
                    .keyboardShortcut("e")
                    .disabled(model.editor == nil)
            }
            // Single-key shortcuts (Space / I / O / ← →) are handled by EditorKeyMonitor so they
            // don't swallow typing in text fields; the menu only lists them.
            CommandMenu("播放") {
                Button("播放 / 暂停 (空格)") { model.editor?.togglePlay() }
                    .disabled(model.editor == nil)
                Button("设为起点 (I)") { model.editor?.setTrimStartToCurrent() }
                    .disabled(model.editor == nil)
                Button("设为终点 (O)") { model.editor?.setTrimEndToCurrent() }
                    .disabled(model.editor == nil)
                Divider()
                Button("上一帧 (←)") { model.editor?.step(-1) }
                    .disabled(model.editor == nil)
                Button("下一帧 (→)") { model.editor?.step(1) }
                    .disabled(model.editor == nil)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run); harmless inside the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Developer convenience: GIFTRIM_OPEN=/path/file opens a file at launch.
        if let path = ProcessInfo.processInfo.environment["GIFTRIM_OPEN"] {
            Task { @MainActor in AppModel.shared.open(urls: [URL(fileURLWithPath: path)]) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.open(urls: urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
