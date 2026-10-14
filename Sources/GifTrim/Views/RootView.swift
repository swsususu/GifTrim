import AppKit
import GifTrimCore
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack {
            if let editor = model.editor {
                EditorView(editor: editor)
                    .id(ObjectIdentifier(editor))
            } else {
                WelcomeView()
            }
            if model.isLoading {
                ZStack {
                    Color.black.opacity(0.25)
                    ProgressView("正在载入…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .ignoresSafeArea()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadFileURLs(from: providers) { urls in model.open(urls: urls) }
            return true
        }
        .alert("出错了", isPresented: Binding(get: { model.errorMessage != nil },
                                            set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: $model.showCamera) {
            CameraRecorderView { url in
                model.showCamera = false
                if let url { model.open(urls: [url]) }
            }
        }
    }
}

/// Resolves dropped file URLs (in drop order) and calls back on the main actor.
func loadFileURLs(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var results = [(Int, URL)]()
    for (i, p) in providers.enumerated() where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); results.append((i, url)); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        let urls = results.sorted { $0.0 < $1.0 }.map(\.1)
        MainActor.assumeIsolated { completion(urls) }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: "film.stack")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(.tint)
                Text("GifTrim")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("把视频、动图和图片变成高质量 GIF")
                    .foregroundStyle(.secondary)
            }

            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(hovering ? Color.accentColor : Color.secondary.opacity(0.5))
                .background(RoundedRectangle(cornerRadius: 16).fill(hovering ? Color.accentColor.opacity(0.08) : .clear))
                .frame(width: 520, height: 200)
                .overlay {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                        Text("把文件拖到这里")
                            .font(.title3.weight(.medium))
                        Text("支持 MOV / MP4 / M4V、GIF / APNG / WebP，或多张图片")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $hovering) { providers in
                    loadFileURLs(from: providers) { urls in model.open(urls: urls) }
                    return true
                }
                .onTapGesture { model.showOpenPanel() }

            HStack(spacing: 14) {
                WelcomeButton(title: "打开文件", symbol: "folder", shortcut: "⌘O") { model.showOpenPanel() }
                WelcomeButton(title: "录制屏幕", symbol: "record.circle", shortcut: "⇧⌘R") { model.startScreenRecording() }
                WelcomeButton(title: "摄像头 / iPhone", symbol: "camera", shortcut: "⇧⌘C") { model.showCamera = true }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WelcomeButton: View {
    let title: String
    let symbol: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.callout.weight(.medium))
                Text(shortcut).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 150, height: 86)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }
}
