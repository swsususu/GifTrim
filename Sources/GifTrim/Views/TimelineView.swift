import GifTrimCore
import SwiftUI

/// Thumbnail strip with trim handles and a playhead.
struct TimelineView: View {
    @Bindable var editor: EditorModel
    @State private var dragStartValue: Double?
    @State private var dragTarget: DragTarget?

    private enum DragTarget { case start, end, scrub }

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

            handle(at: startX - handleW / 2 + 2, width: handleW, height: height)
            handle(at: endX - handleW / 2 - 2, width: handleW, height: height)

            // Playhead
            Rectangle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.6), radius: 1)
                .frame(width: 2, height: height + 8)
                .offset(x: x(editor.currentTime) - 1, y: -4)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        // Extend the hit area past the edges so a handle sitting at 0 or the end is easy to grab.
        .contentShape(Rectangle().inset(by: -10))
        // One gesture for the whole strip: it picks the handle nearest to where the drag starts,
        // so sibling gestures can't steal it (the start handle used to lose to the scrubber).
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                editor.pause()
                if dragTarget == nil {
                    let x0 = v.startLocation.x
                    let dStart = abs(x0 - startX)
                    let dEnd = abs(x0 - endX)
                    let grab: CGFloat = 12
                    if dStart <= grab || dEnd <= grab {
                        // Overlapping handles: pick by side, so a collapsed range can still be widened.
                        let pickStart = dStart < dEnd || (dStart == dEnd && x0 <= startX)
                        dragTarget = pickStart ? .start : .end
                        dragStartValue = pickStart ? editor.project.trimStart : editor.project.trimEnd
                    } else {
                        dragTarget = .scrub
                    }
                }
                let minLen = min(EditorModel.minTrimLength, duration)
                switch dragTarget {
                case .start:
                    let t = (dragStartValue ?? 0) + Double(v.translation.width / width) * duration
                    editor.project.trimStart = max(0, min(t, editor.project.trimEnd - minLen))
                    editor.seek(to: editor.project.trimStart)
                case .end:
                    let t = (dragStartValue ?? 0) + Double(v.translation.width / width) * duration
                    editor.project.trimEnd = min(duration, max(t, editor.project.trimStart + minLen))
                    editor.seek(to: editor.project.trimEnd)
                case .scrub, nil:
                    editor.seek(to: Double(v.location.x / width) * duration)
                }
            }
            .onEnded { _ in
                let wasTrim = dragTarget == .start || dragTarget == .end
                dragTarget = nil
                dragStartValue = nil
                if wasTrim { editor.projectDidChange() }
            })
    }

    /// Thumbnails (count adapts to width so each keeps the source aspect ratio).
    private func thumbnailStrip(width: CGFloat, height: CGFloat, duration: Double) -> some View {
        let aspect: CGFloat = editor.source.size.width / max(1, editor.source.size.height)
        let tileWidth: CGFloat = max(1, height * aspect)
        let rawCount: CGFloat = height > 1 && width.isFinite ? (width / tileWidth).rounded(.up) : 1
        let count: Int = Int(min(200, max(1, rawCount)))
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
    }

    private static func thumb(_ thumbs: [CGImage], tile i: Int, of count: Int) -> CGImage? {
        guard !thumbs.isEmpty else { return nil }
        let pos = (Double(i) + 0.5) / Double(count) * Double(thumbs.count)
        return thumbs[min(thumbs.count - 1, Int(pos))]
    }

    private func handle(at offsetX: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.yellow)
            .overlay(Capsule().fill(Color.black.opacity(0.5)).frame(width: 2, height: height * 0.4))
            .frame(width: width, height: height)
            .offset(x: offsetX)
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
