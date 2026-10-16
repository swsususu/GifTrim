import CoreGraphics
import Foundation

/// sRGB color with components in 0...1.
public struct RGBAColor: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let white = RGBAColor(r: 1, g: 1, b: 1)
    public static let black = RGBAColor(r: 0, g: 0, b: 0)
    public static let yellow = RGBAColor(r: 1, g: 0.85, b: 0.1)

    public var cgColor: CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    public init(cgColor: CGColor) {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil) ?? cgColor
        let c = converted.components ?? [1, 1, 1, 1]
        if c.count >= 4 {
            self.init(r: c[0], g: c[1], b: c[2], a: c[3])
        } else if c.count == 2 {
            self.init(r: c[0], g: c[0], b: c[0], a: c[1])
        } else {
            self.init(r: 1, g: 1, b: 1)
        }
    }
}

/// A rectangle in normalized (0...1) coordinates with a top-left origin.
public struct NormalizedRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    public var isFull: Bool {
        abs(x) < 1e-6 && abs(y) < 1e-6 && abs(width - 1) < 1e-6 && abs(height - 1) < 1e-6
    }

    /// Clamps the rect to the unit square and enforces a minimum size.
    public func clamped(minSize: Double = 0.02) -> NormalizedRect {
        var w = min(max(width, minSize), 1)
        var h = min(max(height, minSize), 1)
        var nx = min(max(x, 0), 1 - w)
        var ny = min(max(y, 0), 1 - h)
        if !nx.isFinite { nx = 0 }
        if !ny.isFinite { ny = 0 }
        if !w.isFinite { w = 1 }
        if !h.isFinite { h = 1 }
        return NormalizedRect(x: nx, y: ny, width: w, height: h)
    }

    /// Pixel rect (top-left origin) for a given image size, rounded to whole pixels.
    public func pixelRect(in size: CGSize) -> CGRect {
        let px = min(max((x * size.width).rounded(), 0), max(0, size.width - 1))
        let py = min(max((y * size.height).rounded(), 0), max(0, size.height - 1))
        let pw = max(1, (width * size.width).rounded())
        let ph = max(1, (height * size.height).rounded())
        return CGRect(x: px, y: py, width: max(1, min(pw, size.width - px)), height: max(1, min(ph, size.height - py)))
    }

    /// Returns a centered rect of the given aspect ratio (width / height) inside a frame of `size`.
    public static func centered(aspect: Double, in size: CGSize) -> NormalizedRect {
        guard aspect > 0, size.width > 0, size.height > 0 else { return .full }
        let sourceAspect = size.width / size.height
        if aspect > sourceAspect {
            let h = sourceAspect / aspect
            return NormalizedRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
        } else {
            let w = aspect / sourceAspect
            return NormalizedRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        }
    }
}

public struct NormalizedPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum PlaybackMode: String, Codable, CaseIterable, Sendable {
    case forward
    case reverse
    case bounce
}

public enum ColorEffect: String, Codable, CaseIterable, Sendable {
    case none
    case mono
    case noir
    case tonal
    case sepia
    case chrome
    case fade
    case instant
    case process
    case transfer
    case invert
    case posterize
    case comic
}

public struct Adjustments: Codable, Hashable, Sendable {
    /// -1...1, 0 = unchanged
    public var brightness: Double = 0
    /// 0.25...2, 1 = unchanged
    public var contrast: Double = 1
    /// 0...2, 1 = unchanged
    public var saturation: Double = 1
    /// 0...2, 0 = off
    public var sharpness: Double = 0
    /// 0...2, 0 = off
    public var vignette: Double = 0
    public var effect: ColorEffect = .none

    public init() {}

    public var isIdentity: Bool {
        brightness == 0 && contrast == 1 && saturation == 1 && sharpness == 0 && vignette == 0 && effect == .none
    }
}

public enum TextAlignmentMode: String, Codable, CaseIterable, Sendable {
    case left
    case center
    case right
}

public struct TextOverlay: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var text: String
    /// PostScript font name.
    public var fontName: String = "HelveticaNeue-Bold"
    /// Font size as a fraction of the output height.
    public var fontSize: Double = 0.12
    public var color: RGBAColor = .white
    public var strokeColor: RGBAColor = .black
    /// Stroke width as a fraction of the font size (0 disables the stroke).
    public var strokeWidth: Double = 0.08
    public var shadow: Bool = false
    public var alignment: TextAlignmentMode = .center
    /// Center of the text block, normalized to the output frame (top-left origin).
    public var position = NormalizedPoint(x: 0.5, y: 0.85)
    /// Visible interval in source-time seconds. `nil` means unbounded.
    public var startTime: Double?
    public var endTime: Double?

    public init(text: String) {
        self.text = text
    }

    public func isVisible(at time: Double) -> Bool {
        if let s = startTime, time < s - 1e-6 { return false }
        if let e = endTime, time > e + 1e-6 { return false }
        return true
    }
}

public struct ImageOverlay: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    /// Encoded image data (PNG/JPEG/...).
    public var imageData: Data
    public var name: String = ""
    /// Center of the image, normalized to the output frame (top-left origin).
    public var position = NormalizedPoint(x: 0.85, y: 0.85)
    /// Width as a fraction of the output width.
    public var width: Double = 0.2
    public var opacity: Double = 1
    public var startTime: Double?
    public var endTime: Double?

    public init(imageData: Data, name: String = "") {
        self.imageData = imageData
        self.name = name
    }

    public func isVisible(at time: Double) -> Bool {
        if let s = startTime, time < s - 1e-6 { return false }
        if let e = endTime, time > e + 1e-6 { return false }
        return true
    }
}

/// A user-managed output frame.
public struct FrameEdit: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    /// Time in the source (seconds) to take the image from.
    public var sourceTime: Double
    /// How long the frame stays on screen in the GIF (seconds).
    public var delay: Double

    public init(sourceTime: Double, delay: Double) {
        self.sourceTime = sourceTime
        self.delay = delay
    }
}

public struct ExportSettings: Codable, Hashable, Sendable {
    /// Output width in pixels. Clamped to the cropped source width.
    public var width: Int = 480
    /// Output frame rate. GIF supports at most 50 fps.
    public var fps: Double = 15
    /// 1...100
    public var quality: Int = 90
    /// 1...100, nil = same as quality. Lower adds noise but reduces size.
    public var lossyQuality: Int?
    /// 1...100, nil = same as quality. Lower smears motion but reduces size.
    public var motionQuality: Int?
    /// 0 = loop forever, -1 = play once, n > 0 = repeat n extra times.
    public var repeatCount: Int = 0
    /// Playback speed multiplier.
    public var speed: Double = 1
    public var playbackMode: PlaybackMode = .forward
    /// Faster, lower quality encoding.
    public var fast: Bool = false
    /// For animated image sources: keep their original frame timing instead of resampling at `fps`.
    public var useSourceTiming: Bool = true

    public init() {}

    public static let maxFPS: Double = 50
}

public struct ExportPreset: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var width: Int?
    public var fps: Double
    public var quality: Int

    public static let all: [ExportPreset] = [
        ExportPreset(id: "original", name: "原始尺寸 · 高质量", width: nil, fps: 25, quality: 95),
        ExportPreset(id: "hd", name: "高清 800px", width: 800, fps: 20, quality: 90),
        ExportPreset(id: "balanced", name: "均衡 640px", width: 640, fps: 15, quality: 85),
        ExportPreset(id: "social", name: "社交 480px", width: 480, fps: 15, quality: 80),
        ExportPreset(id: "small", name: "小体积 320px", width: 320, fps: 12, quality: 70),
        ExportPreset(id: "sticker", name: "表情 240px", width: 240, fps: 10, quality: 75),
    ]
}

/// Everything needed to turn a source into a GIF.
public struct Project: Codable, Hashable, Sendable {
    public var sourceURL: URL
    public var trimStart: Double
    public var trimEnd: Double
    public var crop: NormalizedRect = .full
    public var settings = ExportSettings()
    public var adjustments = Adjustments()
    public var texts: [TextOverlay] = []
    public var images: [ImageOverlay] = []
    /// When set, overrides the automatically planned frames.
    public var customFrames: [FrameEdit]?

    public init(sourceURL: URL, trimStart: Double, trimEnd: Double) {
        self.sourceURL = sourceURL
        self.trimStart = trimStart
        self.trimEnd = trimEnd
    }

    /// Output pixel size for a source of `sourceSize` (oriented).
    public func outputSize(sourceSize: CGSize) -> CGSize {
        Self.outputSize(sourceSize: sourceSize, crop: crop, width: settings.width)
    }

    public static func outputSize(sourceSize: CGSize, crop: NormalizedRect, width: Int) -> CGSize {
        let cropPx = crop.clamped().pixelRect(in: sourceSize)
        let w = max(1, min(Double(width), cropPx.width.rounded()))
        let h = max(1, (w * cropPx.height / cropPx.width).rounded())
        return CGSize(width: w, height: h)
    }
}
