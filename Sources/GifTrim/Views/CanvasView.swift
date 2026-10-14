import AppKit
import AVFoundation
import GifTrimCore
import SwiftUI

/// Shows the current frame. In the crop tab the full frame is shown with an editable crop box;
/// otherwise only the cropped region is shown, with draggable text/image overlays (WYSIWYG).
struct CanvasView: View {
    @Bindable var editor: EditorModel

    var body: some View {
        GeometryReader { geo in
            let area = CGRect(origin: .zero, size: geo.size).insetBy(dx: 16, dy: 16)
            let cropping = editor.inspectorTab == .crop
            let src = editor.source.size
            let crop = cropping ? NormalizedRect.full : editor.project.crop.clamped()
            let cropPx = crop.pixelRect(in: src)
            let fit = aspectFit(cropPx.size, in: area)
            // Full source frame positioned so that the crop region fills `fit`.
            let scale = fit.width / cropPx.width
            let full = CGRect(x: fit.minX - cropPx.minX * scale, y: fit.minY - cropPx.minY * scale,
                              width: src.width * scale, height: src.height * scale)

            ZStack(alignment: .topLeading) {
                Checkerboard()
                    .frame(width: fit.width, height: fit.height)
                    .offset(x: fit.minX, y: fit.minY)

                FrameContent(editor: editor)
                    .frame(width: full.width, height: full.height)
                    .offset(x: full.minX, y: full.minY)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    .mask {
                        Rectangle()
                            .frame(width: fit.width, height: fit.height)
                            .offset(x: fit.minX, y: fit.minY)
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    }

                if cropping {
                    CropOverlay(editor: editor, frameRect: fit)
                } else {
                    OverlayEditor(editor: editor, rect: fit)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
    guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return .zero }
    let s = min(rect.width / size.width, rect.height / size.height)
    let w = (size.width * s).rounded()
    let h = (size.height * s).rounded()
    return CGRect(x: (rect.midX - w / 2).rounded(), y: (rect.midY - h / 2).rounded(), width: w, height: h)
}

private struct FrameContent: View {
    let editor: EditorModel

    var body: some View {
        if let player = editor.player {
            PlayerLayerView(player: player)
        } else if let frame = editor.displayFrame {
            Image(decorative: frame, scale: 1)
                .resizable()
                .interpolation(.high)
        } else {
            Color.black
        }
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let v = PlayerNSView()
        v.playerLayer.player = player
        return v
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        if nsView.playerLayer.player !== player { nsView.playerLayer.player = player }
    }

    final class PlayerNSView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resize
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 10
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(Color(white: 0.85)))
                }
            }
        }
    }
}

// MARK: - Overlays (text & images)

private struct OverlayEditor: View {
    @Bindable var editor: EditorModel
    let rect: CGRect
    @State private var dragStart: NormalizedPoint?
    @State private var editingTextID: UUID?

    var body: some View {
        let size = rect.size
        let overlayImage = renderOverlays(size: size)
        ZStack(alignment: .topLeading) {
            if let overlayImage {
                Image(decorative: overlayImage, scale: 2)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
            }
            ForEach(editor.project.images) { overlay in
                let b = imageBounds(overlay, size: size)
                handleBox(selected: editor.selectedImageID == overlay.id, bounds: b, size: size)
                    .gesture(dragGesture(size: size,
                                         get: { editor.project.images.first { $0.id == overlay.id }?.position },
                                         set: { p in
                                             if let i = editor.project.images.firstIndex(where: { $0.id == overlay.id }) {
                                                 editor.project.images[i].position = p
                                             }
                                         },
                                         select: {
                                             editor.selectedImageID = overlay.id
                                             editor.inspectorTab = .image
                                         }))
            }
            ForEach(editor.project.texts) { text in
                let b = Compositor.textBounds(text, size: size)
                handleBox(selected: editor.selectedTextID == text.id, bounds: b, size: size, padding: 6)
                    .gesture(dragGesture(size: size,
                                         get: { editor.project.texts.first { $0.id == text.id }?.position },
                                         set: { p in
                                             if let i = editor.project.texts.firstIndex(where: { $0.id == text.id }) {
                                                 editor.project.texts[i].position = p
                                             }
                                         },
                                         select: {
                                             editor.selectedTextID = text.id
                                             editor.inspectorTab = .text
                                         }))
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        editor.selectedTextID = text.id
                        editor.inspectorTab = .text
                        editor.focusTextEditor = true
                    })
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .offset(x: rect.minX, y: rect.minY)
    }

    private func renderOverlays(size: CGSize) -> CGImage? {
        let project = editor.project
        guard !project.texts.isEmpty || !project.images.isEmpty, size.width >= 1, size.height >= 1 else { return nil }
        let scale: CGFloat = 2
        let w = Int(size.width * scale)
        let h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let compositor = Compositor(project: project, sourceSize: editor.source.size,
                                    outputSize: CGSize(width: w, height: h))
        compositor.drawOverlays(in: ctx, size: CGSize(width: w, height: h), time: editor.currentTime)
        return ctx.makeImage()
    }

    private func imageBounds(_ overlay: ImageOverlay, size: CGSize) -> NormalizedRect {
        let aspect: Double = {
            guard let img = NSImage(data: overlay.imageData), img.size.width > 0 else { return 1 }
            return img.size.height / img.size.width
        }()
        let w = overlay.width
        let h = w * aspect * size.width / max(1, size.height)
        return NormalizedRect(x: overlay.position.x - w / 2, y: overlay.position.y - h / 2, width: w, height: h)
    }

    private func handleBox(selected: Bool, bounds b: NormalizedRect, size: CGSize, padding: CGFloat = 0) -> some View {
        let r = CGRect(x: b.x * size.width, y: b.y * size.height, width: b.width * size.width, height: b.height * size.height)
            .insetBy(dx: -padding, dy: -padding)
        return Rectangle()
            .fill(Color.white.opacity(0.001))
            .overlay {
                Rectangle()
                    .strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.6),
                                  style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [4, 3]))
            }
            .frame(width: max(12, r.width), height: max(12, r.height))
            .offset(x: r.minX, y: r.minY)
            .contentShape(Rectangle())
    }

    private func dragGesture(size: CGSize, get: @escaping () -> NormalizedPoint?,
                             set: @escaping (NormalizedPoint) -> Void,
                             select: @escaping () -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragStart == nil {
                    dragStart = get()
                    select()
                }
                guard let start = dragStart else { return }
                var p = NormalizedPoint(x: start.x + v.translation.width / size.width,
                                        y: start.y + v.translation.height / size.height)
                p.x = min(max(p.x, 0), 1)
                p.y = min(max(p.y, 0), 1)
                // Snap to horizontal center.
                if abs(p.x - 0.5) < 0.015 { p.x = 0.5 }
                set(p)
            }
            .onEnded { _ in
                dragStart = nil
                editor.projectDidChange()
            }
    }
}

// MARK: - Crop

private struct CropOverlay: View {
    @Bindable var editor: EditorModel
    let frameRect: CGRect
    @State private var startCrop: NormalizedRect?

    enum Handle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move }

    var body: some View {
        let c = editor.project.crop.clamped()
        let r = CGRect(x: frameRect.minX + c.x * frameRect.width, y: frameRect.minY + c.y * frameRect.height,
                       width: c.width * frameRect.width, height: c.height * frameRect.height)
        ZStack(alignment: .topLeading) {
            // Dim outside the crop.
            Path { p in
                p.addRect(frameRect)
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            // Rule of thirds.
            Path { p in
                for i in 1...2 {
                    let x = r.minX + r.width * CGFloat(i) / 3
                    let y = r.minY + r.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                    p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .background(Color.white.opacity(0.001))
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .gesture(drag(.move))

            ForEach(Array(Handle.allCases.dropLast().enumerated()), id: \.offset) { _, h in
                let p = point(for: h, in: r)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .shadow(radius: 1)
                    .frame(width: 12, height: 12)
                    .offset(x: p.x - 6, y: p.y - 6)
                    .gesture(drag(h))
            }

            Text("\(Int(c.pixelRect(in: editor.source.size).width)) × \(Int(c.pixelRect(in: editor.source.size).height))")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.6), in: Capsule())
                .foregroundStyle(.white)
                .offset(x: r.minX + 6, y: r.minY + 6)
                .allowsHitTesting(false)
        }
    }

    private func point(for h: Handle, in r: CGRect) -> CGPoint {
        switch h {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        case .move: return CGPoint(x: r.midX, y: r.midY)
        }
    }

    private func drag(_ h: Handle) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if startCrop == nil { startCrop = editor.project.crop.clamped() }
                guard let s = startCrop else { return }
                let dx = v.translation.width / frameRect.width
                let dy = v.translation.height / frameRect.height
                editor.project.crop = resize(s, handle: h, dx: dx, dy: dy)
            }
            .onEnded { _ in
                startCrop = nil
                editor.projectDidChange()
            }
    }

    private func resize(_ s: NormalizedRect, handle: Handle, dx: Double, dy: Double) -> NormalizedRect {
        if handle == .move {
            var r = s
            r.x = min(max(0, s.x + dx), 1 - s.width)
            r.y = min(max(0, s.y + dy), 1 - s.height)
            return r
        }
        var minX = s.x, minY = s.y, maxX = s.x + s.width, maxY = s.y + s.height
        switch handle {
        case .topLeft: minX += dx; minY += dy
        case .top: minY += dy
        case .topRight: maxX += dx; minY += dy
        case .right: maxX += dx
        case .bottomRight: maxX += dx; maxY += dy
        case .bottom: maxY += dy
        case .bottomLeft: minX += dx; maxY += dy
        case .left: minX += dx
        case .move: break
        }
        let minSize = 0.03
        minX = min(max(0, minX), maxX - minSize)
        minY = min(max(0, minY), maxY - minSize)
        maxX = max(min(1, maxX), minX + minSize)
        maxY = max(min(1, maxY), minY + minSize)
        var r = NormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        // Enforce the locked aspect ratio (in pixels), anchored to the opposite edge/corner.
        if let aspect = editor.cropAspect {
            let src = editor.source.size
            let normAspect = aspect * src.height / src.width // width/height in normalized units
            let horizontalDriven = [.left, .right].contains(handle) ||
                ([.topLeft, .topRight, .bottomLeft, .bottomRight].contains(handle) && abs(dx) >= abs(dy))
            var w = r.width, hgt = r.height
            if horizontalDriven { hgt = w / normAspect } else { w = hgt * normAspect }
            if hgt > 1 { hgt = 1; w = hgt * normAspect }
            if w > 1 { w = 1; hgt = w / normAspect }
            let anchorRight = [.topLeft, .left, .bottomLeft].contains(handle)
            let anchorBottom = [.topLeft, .top, .topRight].contains(handle)
            var x = anchorRight ? (s.x + s.width) - w : s.x
            var y = anchorBottom ? (s.y + s.height) - hgt : s.y
            if handle == .top || handle == .bottom { x = s.x + s.width / 2 - w / 2 }
            if handle == .left || handle == .right { y = s.y + s.height / 2 - hgt / 2 }
            x = min(max(0, x), 1 - w)
            y = min(max(0, y), 1 - hgt)
            r = NormalizedRect(x: x, y: y, width: w, height: hgt)
        }
        return r
    }
}
