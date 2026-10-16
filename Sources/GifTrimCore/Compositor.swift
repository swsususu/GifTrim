import Accelerate
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import ImageIO

/// Applies crop, scale, adjustments and overlays to source frames.
public final class Compositor: @unchecked Sendable {
    public let outputSize: CGSize
    let sourceSize: CGSize
    let crop: NormalizedRect
    let adjustments: Adjustments
    let texts: [TextOverlay]
    let images: [(ImageOverlay, CGImage)]
    let context: CIContext

    public init(project: Project, sourceSize: CGSize, outputSize: CGSize? = nil, context: CIContext? = nil) {
        self.sourceSize = sourceSize
        self.crop = project.crop.clamped()
        self.outputSize = outputSize ?? project.outputSize(sourceSize: sourceSize)
        self.adjustments = project.adjustments
        self.texts = project.texts
        self.images = project.images.compactMap { overlay in
            guard let src = CGImageSourceCreateWithData(overlay.imageData as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            return (overlay, img)
        }
        self.context = context ?? SharedCIContext.shared
    }

    public var hasOverlays: Bool { !texts.isEmpty || !images.isEmpty }

    // MARK: - Core Image stage

    /// Crops, scales and color-adjusts a full source frame (extent = source size, origin zero).
    public func process(_ input: CIImage) -> CIImage {
        var image = input
        let extent = image.extent
        if extent.origin != .zero {
            image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        }
        // Crop (convert top-left normalized rect to CI bottom-left coordinates).
        let px = crop.pixelRect(in: sourceSize)
        let ciCrop = CGRect(x: px.minX, y: sourceSize.height - px.maxY, width: px.width, height: px.height)
        if !crop.isFull {
            image = image.cropped(to: ciCrop)
                .transformed(by: CGAffineTransform(translationX: -ciCrop.minX, y: -ciCrop.minY))
        }
        // Scale to the exact output size.
        let sx = outputSize.width / ciCrop.width
        let sy = outputSize.height / ciCrop.height
        let outRect = CGRect(origin: .zero, size: outputSize)
        if abs(sx - 1) > 1e-4 || abs(sy - 1) > 1e-4 {
            let lanczos = CIFilter.lanczosScaleTransform()
            lanczos.inputImage = image.clampedToExtent()
            lanczos.scale = Float(sy)
            lanczos.aspectRatio = Float(sx / sy)
            image = lanczos.outputImage ?? image
        }
        image = image.cropped(to: outRect)
        image = applyAdjustments(image, rect: outRect)
        return image.cropped(to: outRect)
    }

    func applyAdjustments(_ input: CIImage, rect: CGRect) -> CIImage {
        let a = adjustments
        if a.isIdentity { return input }
        var image = input
        if a.brightness != 0 || a.contrast != 1 || a.saturation != 1 {
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.brightness = Float(a.brightness)
            f.contrast = Float(a.contrast)
            f.saturation = Float(a.saturation)
            image = f.outputImage ?? image
        }
        if a.sharpness > 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = image
            f.sharpness = Float(a.sharpness)
            f.radius = Float(max(1, rect.width / 400))
            image = f.outputImage ?? image
        }
        image = Self.applyEffect(a.effect, to: image)
        if a.vignette > 0 {
            let f = CIFilter.vignetteEffect()
            f.inputImage = image
            f.center = CGPoint(x: rect.midX, y: rect.midY)
            f.radius = Float(hypot(rect.width, rect.height) / 2)
            f.intensity = Float(a.vignette)
            f.falloff = 0.5
            image = f.outputImage ?? image
        }
        return image
    }

    static func applyEffect(_ effect: ColorEffect, to image: CIImage) -> CIImage {
        let filter: CIFilter?
        switch effect {
        case .none: return image
        case .mono: filter = CIFilter.photoEffectMono()
        case .noir: filter = CIFilter.photoEffectNoir()
        case .tonal: filter = CIFilter.photoEffectTonal()
        case .chrome: filter = CIFilter.photoEffectChrome()
        case .fade: filter = CIFilter.photoEffectFade()
        case .instant: filter = CIFilter.photoEffectInstant()
        case .process: filter = CIFilter.photoEffectProcess()
        case .transfer: filter = CIFilter.photoEffectTransfer()
        case .sepia:
            let f = CIFilter.sepiaTone()
            f.intensity = 0.9
            filter = f
        case .invert: filter = CIFilter.colorInvert()
        case .posterize:
            let f = CIFilter.colorPosterize()
            f.levels = 6
            filter = f
        case .comic: filter = CIFilter.comicEffect()
        }
        guard let filter else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage?.cropped(to: image.extent) ?? image
    }

    // MARK: - Rendering

    /// Renders a processed frame plus overlays into `buffer` (RGBA, non-premultiplied, sRGB).
    public func render(_ source: CIImage, time: Double, into buffer: RGBABuffer) {
        let processed = process(source)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        context.render(processed, toBitmap: buffer.data, rowBytes: buffer.bytesPerRow,
                       bounds: CGRect(origin: .zero, size: outputSize), format: .RGBA8, colorSpace: srgb)
        if hasOverlays, let cg = buffer.makeContext() {
            drawOverlays(in: cg, size: outputSize, time: time)
        }
        buffer.unpremultiply()
    }

    /// Renders to a CGImage (used for previews).
    public func renderImage(_ source: CIImage, time: Double) -> CGImage? {
        let buffer = RGBABuffer(width: Int(outputSize.width), height: Int(outputSize.height))
        let processed = process(source)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        context.render(processed, toBitmap: buffer.data, rowBytes: buffer.bytesPerRow,
                       bounds: CGRect(origin: .zero, size: outputSize), format: .RGBA8, colorSpace: srgb)
        guard let cg = buffer.makeContext() else { return nil }
        if hasOverlays { drawOverlays(in: cg, size: outputSize, time: time) }
        return cg.makeImage()
    }

    /// Draws text and image overlays into a context whose origin is bottom-left and size is `size`.
    public func drawOverlays(in ctx: CGContext, size: CGSize, time: Double) {
        for (overlay, image) in images where overlay.isVisible(at: time) {
            let w = size.width * overlay.width
            let h = w * Double(image.height) / Double(max(1, image.width))
            let cx = size.width * overlay.position.x
            let cy = size.height * (1 - overlay.position.y)
            ctx.saveGState()
            ctx.setAlpha(overlay.opacity)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
            ctx.restoreGState()
        }
        for text in texts where text.isVisible(at: time) {
            Self.draw(text: text, in: ctx, size: size)
        }
    }

    /// Lays out a text overlay; returns the block rect in top-left normalized coordinates.
    public static func textBounds(_ text: TextOverlay, size: CGSize) -> NormalizedRect {
        let layout = TextLayout(text: text, size: size)
        let rect = layout.blockRect
        return NormalizedRect(x: rect.minX / size.width,
                              y: 1 - rect.maxY / size.height,
                              width: rect.width / size.width,
                              height: rect.height / size.height)
    }

    static func draw(text: TextOverlay, in ctx: CGContext, size: CGSize) {
        let layout = TextLayout(text: text, size: size)
        guard !layout.lines.isEmpty else { return }
        ctx.saveGState()
        ctx.textMatrix = .identity
        if text.shadow {
            ctx.setShadow(offset: CGSize(width: layout.fontSize * 0.04, height: -layout.fontSize * 0.06),
                          blur: layout.fontSize * 0.12,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.75))
        }
        // Stroke first (behind fill) so the fill keeps its full width.
        if text.strokeWidth > 0 {
            ctx.saveGState()
            ctx.setLineJoin(.round)
            ctx.setLineWidth(layout.fontSize * text.strokeWidth * 2)
            ctx.setStrokeColor(text.strokeColor.cgColor)
            ctx.setTextDrawingMode(.stroke)
            for line in layout.lines {
                ctx.textPosition = line.origin
                drawLine(line.strokeLine, in: ctx)
            }
            ctx.restoreGState()
        }
        ctx.setTextDrawingMode(.fill)
        for line in layout.lines {
            ctx.textPosition = line.origin
            CTLineDraw(line.fillLine, ctx)
        }
        ctx.restoreGState()
    }

    /// Draws glyph runs honoring the context's text drawing mode (CTLineDraw resets it).
    private static func drawLine(_ line: CTLine, in ctx: CGContext) {
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        let origin = ctx.textPosition
        // CTFontDrawGlyphs applies the text matrix (including textPosition); reset it so
        // the origin is applied exactly once via the shifted positions below.
        ctx.textPosition = .zero
        defer { ctx.textPosition = origin }
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            let attrs = CTRunGetAttributes(run) as NSDictionary
            // swiftlint:disable:next force_cast
            let font = attrs[kCTFontAttributeName] as! CTFont
            let shifted = positions.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
            CTFontDrawGlyphs(font, glyphs, shifted, count, ctx)
        }
    }
}

/// Line layout for a text overlay in bottom-left pixel coordinates.
struct TextLayout {
    struct Line {
        let fillLine: CTLine
        let strokeLine: CTLine
        let origin: CGPoint
    }

    let lines: [Line]
    let blockRect: CGRect
    let fontSize: CGFloat

    init(text: TextOverlay, size: CGSize) {
        let fontSize = max(4, size.height * text.fontSize)
        self.fontSize = fontSize
        let font = CTFontCreateWithName(text.fontName as CFString, fontSize, nil)
        let fillAttrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): text.color.cgColor,
        ]
        let strokeAttrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): text.strokeColor.cgColor,
        ]
        let rawLines = text.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = max(CTFontGetLeading(font), fontSize * 0.1)
        let lineHeight = ascent + descent + leading

        var measured: [(CTLine, CTLine, CGFloat)] = []
        for raw in rawLines {
            let fill = CTLineCreateWithAttributedString(NSAttributedString(string: raw, attributes: fillAttrs))
            let stroke = CTLineCreateWithAttributedString(NSAttributedString(string: raw, attributes: strokeAttrs))
            let width = CGFloat(CTLineGetTypographicBounds(fill, nil, nil, nil))
            measured.append((fill, stroke, width))
        }
        let blockWidth = measured.map(\.2).max() ?? 0
        let blockHeight = CGFloat(measured.count) * lineHeight - leading
        let cx = size.width * text.position.x
        let cy = size.height * (1 - text.position.y)
        let blockRect = CGRect(x: cx - blockWidth / 2, y: cy - blockHeight / 2, width: blockWidth, height: blockHeight)

        var lines: [Line] = []
        let hasVisibleText = rawLines.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if hasVisibleText {
            for (i, (fill, stroke, width)) in measured.enumerated() {
                let x: CGFloat
                switch text.alignment {
                case .left: x = blockRect.minX
                case .center: x = blockRect.minX + (blockWidth - width) / 2
                case .right: x = blockRect.maxX - width
                }
                let baseline = blockRect.maxY - ascent - CGFloat(i) * lineHeight
                lines.append(Line(fillLine: fill, strokeLine: stroke, origin: CGPoint(x: x, y: baseline)))
            }
        }
        self.lines = lines
        self.blockRect = blockRect
    }
}

/// An owned RGBA8 pixel buffer (sRGB, top-left first row).
public final class RGBABuffer: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let data: UnsafeMutableRawPointer

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        bytesPerRow = ((width * 4) + 63) & ~63
        data = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * height, alignment: 64)
        data.initializeMemory(as: UInt8.self, repeating: 0, count: bytesPerRow * height)
    }

    deinit {
        data.deallocate()
    }

    public var byteCount: Int { bytesPerRow * height }

    /// A CGContext drawing into this buffer with a bottom-left origin (matching Core Image output rows).
    func makeContext() -> CGContext? {
        let ctx = CGContext(data: data, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return ctx
    }

    func unpremultiply() {
        var buf = vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow)
        vImageUnpremultiplyData_RGBA8888(&buf, &buf, vImage_Flags(kvImageNoFlags))
    }

    public func copy(to destination: UnsafeMutableRawPointer) {
        destination.copyMemory(from: data, byteCount: byteCount)
    }
}
