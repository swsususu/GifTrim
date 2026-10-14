import GifTrimCore
import SwiftUI

/// Thumbnail strip with trim handles and a playhead.
struct TimelineView: View {
    @Bindable var editor: EditorModel
    @State private var dragStartValue: Double?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { editor.togglePlay() } label: {
                    Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .help("播放 / 暂停 (空格)")
                Button { editor.step(-1) } label: { Image(systemName: "backward.frame.fill") }
                    .help("上一帧 (←)")
                Button { editor.step(1) } label: { Image(systemName: "forward.frame.fill") }
                    .help("下一帧 (→)")

                Text(formatTime(editor.currentTime))
                    .font(.callout.monospacedDigit())
                    .frame(width: 70, alignment: .leading)

                Spacer()

                Button("设为起点") { editor.setTrimStartToCurrent() }.help("快捷键 I")
                Text("\(formatTime(editor.project.trimStart)) – \(formatTime(editor.project.trimEnd))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("(\(String(format: "%.2f", editor.trimDuration)) 秒)")
                    .font(.callout.monospacedDigit())
                Button("设为终点") { editor.setTrimEndToCurrent() }.help("快捷键 O")
            }
            .buttonStyle(.borderless)
            .disabled(editor.isFrameEditing)

            GeometryReader { geo in
                strip(width: geo.size.width, height: geo.size.height)
            }
            .opacity(editor.isFrameEditing ? 0.4 : 1)
            .disabled(editor.isFrameEditing)
            .overlay {
                if editor.isFrameEditing {
                    Text("正在逐帧编辑，截取范围已锁定（在“帧”面板中退出）")
                        .font(.callout)
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func strip(width: CGFloat, height: CGFloat) -> some View {
        let duration = max(editor.source.duration, 0.001)
        let x: (Double) -> CGFloat = { CGFloat($0 / duration) * width }
        let startX = x(editor.project.trimStart)
        let endX = x(editor.project.trimEnd)
        let handleW: CGFloat = 10

        return ZStack(alignment: .topLeading) {
            thumbnailStrip(width: width, height: height, duration: duration)

            // Dim outside trim
            Rectangle().fill(Color.black.opacity(0.55))
                .frame(width: max(0, startX), height: height)
                .allowsHitTesting(false)
            Rectangle().fill(Color.black.opacity(0.55))
                .frame(width: max(0, width - endX), height: height)
                .offset(x: endX)
                .allowsHitTesting(false)

            // Trim frame
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.yellow, lineWidth: 3)
                .frame(width: max(handleW * 2, endX - startX), height: height)
                .offset(x: startX)
                .allowsHitTesting(false)

            handle(at: startX - handleW / 2 + 2, width: handleW, height: height, isStart: true, total: width, duration: duration)
            handle(at: endX - handleW / 2 - 2, width: handleW, height: height, isStart: false, total: width, duration: duration)

            // Playhead
            Rectangle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.6), radius: 1)
                .frame(width: 2, height: height + 8)
                .offset(x: x(editor.currentTime) - 1, y: -4)
                .allowsHitTesting(false)
        }
    }

    /// Thumbnails (count adapts to width so each keeps the source aspect ratio).
    private func thumbnailStrip(width: CGFloat, height: CGFloat, duration: Double) -> some View {
        let aspect: CGFloat = editor.source.size.width / max(1, editor.source.size.height)
        let tileWidth: CGFloat = height * aspect
        let count: Int = max(1, Int((width / tileWidth).rounded(.up)))
        let thumbs: [CGImage] = editor.thumbnails
        return HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                ThumbnailTile(image: Self.thumb(thumbs, tile: i, of: count))
                    .frame(width: tileWidth, height: height)
                    .clipped()
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .clipped()
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            editor.pause()
            editor.seek(to: Double(v.location.x / width) * duration)
        })
    }

    private static func thumb(_ thumbs: [CGImage], tile i: Int, of count: Int) -> CGImage? {
        guard !thumbs.isEmpty else { return nil }
        let pos = (Double(i) + 0.5) / Double(count) * Double(thumbs.count)
        return thumbs[min(thumbs.count - 1, Int(pos))]
    }

    private func handle(at offsetX: CGFloat, width: CGFloat, height: CGFloat, isStart: Bool,
                        total: CGFloat, duration: Double) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.yellow)
            .overlay(Capsule().fill(Color.black.opacity(0.5)).frame(width: 2, height: height * 0.4))
            .frame(width: width, height: height)
            .offset(x: offsetX)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    editor.pause()
                    if dragStartValue == nil {
                        dragStartValue = isStart ? editor.project.trimStart : editor.project.trimEnd
                    }
                    let t = (dragStartValue ?? 0) + Double(v.translation.width / total) * duration
                    let minLen = min(0.05, duration)
                    if isStart {
                        editor.project.trimStart = max(0, min(t, editor.project.trimEnd - minLen))
                        editor.seek(to: editor.project.trimStart)
                    } else {
                        editor.project.trimEnd = min(duration, max(t, editor.project.trimStart + minLen))
                        editor.seek(to: editor.project.trimEnd)
                    }
                }
                .onEnded { _ in
                    dragStartValue = nil
                    editor.projectDidChange()
                })
            .onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.resizeLeftRight.set()
                case .ended: NSCursor.arrow.set()
                }
            }
    }
}

private struct ThumbnailTile: View {
    let image: CGImage?
    var body: some View {
        if let image {
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
        } else {
            Color.black
        }
    }
}
