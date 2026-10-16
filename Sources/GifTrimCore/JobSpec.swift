import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A declarative, JSON-friendly description of a GIF job. Shared by the CLI (`--json` / flags)
/// and the MCP server, so humans, scripts and AI agents all drive exactly the same pipeline.
public struct JobSpec: Codable, Sendable {
    /// One video, one animated image, or several still images (as a sequence).
    public var inputs: [String]
    public var output: String?
    /// Seconds into the source.
    public var start: Double?
    public var end: Double?
    public var width: Int?
    public var fps: Double?
    /// 1-100.
    public var quality: Int?
    public var lossy: Int?
    public var motion: Int?
    public var speed: Double?
    /// forward | reverse | bounce
    public var mode: String?
    /// 0 = loop forever, -1 = play once, n = repeat n times.
    public var loop: Int?
    /// Crop in source pixels.
    public var crop: PixelRect?
    /// Crop to an aspect ratio, centered (e.g. "1:1", "16:9"). Ignored when `crop` is set.
    public var aspect: String?
    public var effect: String?
    public var brightness: Double?
    public var contrast: Double?
    public var saturation: Double?
    public var texts: [TextSpec]?
    /// Kilobytes; picks the largest width that fits.
    public var targetSizeKB: Int?
    public var fast: Bool?

    public struct PixelRect: Codable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
    }

    public struct TextSpec: Codable, Sendable {
        public var text: String
        /// top | center | bottom (default bottom)
        public var position: String?
        /// Fraction of output height (default 0.12).
        public var size: Double?
        /// Hex color like "#FFFFFF".
        public var color: String?
        public var strokeColor: String?
        public var font: String?
        public var start: Double?
        public var end: Double?
        public init(text: String) { self.text = text }
    }

    public init(inputs: [String]) { self.inputs = inputs }
}

/// Machine-readable description of a source file.
public struct SourceInfo: Codable, Sendable {
    public var path: String
    public var kind: String
    public var width: Int
    public var height: Int
    public var duration: Double
    public var frameRate: Double
    public var frameCount: Int?
    public var fileSizeBytes: Int64?
}

/// Machine-readable result of a job.
public struct JobResult: Codable, Sendable {
    public var output: String
    public var width: Int
    public var height: Int
    public var frames: Int
    public var duration: Double
    public var sizeBytes: Int64
    public var elapsedSeconds: Double
}

public struct JobEstimate: Codable, Sendable {
    public var width: Int
    public var height: Int
    public var frames: Int
    public var duration: Double
    public var estimatedBytes: Int64
}

public enum JobError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let m): return m
        }
    }
}

public enum JobRunner {
    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    public static func open(_ spec: JobSpec) async throws -> MediaSource {
        guard !spec.inputs.isEmpty else { throw JobError.invalid("inputs must contain at least one file") }
        let urls = spec.inputs.map(expand)
        for url in urls where !FileManager.default.fileExists(atPath: url.path) {
            throw JobError.invalid("file not found: \(url.path)")
        }
        // Still-image sequences have no intrinsic timing: an explicit fps means one image per frame.
        let still = spec.fps.map { 1 / min(max($0, 0.1), ExportSettings.maxFPS) } ?? 0.5
        return try await MediaSource.open(urls: urls, stillFrameDuration: still)
    }

    public static func info(_ source: MediaSource) -> SourceInfo {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.url.path)
        return SourceInfo(path: source.url.path, kind: source.kind.rawValue,
                          width: Int(source.size.width), height: Int(source.size.height),
                          duration: (source.duration * 1000).rounded() / 1000,
                          frameRate: (source.nominalFrameRate * 100).rounded() / 100,
                          frameCount: source.nativeFrameTimes?.count,
                          fileSizeBytes: (attrs?[.size] as? NSNumber)?.int64Value)
    }

    /// Rejects NaN/infinite numbers, which would otherwise trap in later Int conversions.
    static func requireFinite(_ values: [(String, Double?)]) throws {
        for (name, v) in values {
            if let v, !v.isFinite { throw JobError.invalid("\(name) must be a finite number") }
        }
    }

    /// Builds a project from a spec, validating every field.
    public static func project(_ spec: JobSpec, source: MediaSource) throws -> Project {
        try requireFinite([("start", spec.start), ("end", spec.end), ("fps", spec.fps), ("speed", spec.speed),
                           ("brightness", spec.brightness), ("contrast", spec.contrast),
                           ("saturation", spec.saturation),
                           ("crop.x", spec.crop?.x), ("crop.y", spec.crop?.y),
                           ("crop.width", spec.crop?.width), ("crop.height", spec.crop?.height)])
        for t in spec.texts ?? [] {
            try requireFinite([("text.size", t.size), ("text.start", t.start), ("text.end", t.end)])
        }
        if let w = spec.width, w < 1 { throw JobError.invalid("width must be >= 1") }
        if let kb = spec.targetSizeKB, kb <= 0 || kb > Int.max / 1024 {
            throw JobError.invalid("targetSizeKB must be > 0")
        }
        if let c = spec.crop, c.width <= 0 || c.height <= 0 {
            throw JobError.invalid("crop width and height must be > 0")
        }
        let start = spec.start ?? 0
        let end = spec.end ?? source.duration
        guard start >= 0, start < source.duration else {
            throw JobError.invalid("start must be in [0, \(source.duration)) seconds")
        }
        guard end > start else { throw JobError.invalid("end must be greater than start") }
        var p = Project(sourceURL: source.url, trimStart: start, trimEnd: min(end, source.duration))
        p.settings.width = min(spec.width ?? min(480, Int(source.size.width)), 4096)
        if let fps = spec.fps {
            guard fps > 0 else { throw JobError.invalid("fps must be > 0") }
            p.settings.fps = min(fps, ExportSettings.maxFPS)
        }
        if let q = spec.quality { p.settings.quality = clamp(q) }
        p.settings.lossyQuality = spec.lossy.map(clamp)
        p.settings.motionQuality = spec.motion.map(clamp)
        if let s = spec.speed {
            guard s > 0 else { throw JobError.invalid("speed must be > 0") }
            p.settings.speed = min(max(s, 0.05), 20)
        }
        if let m = spec.mode {
            guard let mode = PlaybackMode(rawValue: m.lowercased()) else {
                throw JobError.invalid("mode must be one of: forward, reverse, bounce")
            }
            p.settings.playbackMode = mode
        }
        if let l = spec.loop { p.settings.repeatCount = l }
        p.settings.fast = spec.fast ?? false

        if let c = spec.crop {
            let s = source.size
            p.crop = NormalizedRect(x: c.x / s.width, y: c.y / s.height,
                                    width: c.width / s.width, height: c.height / s.height).clamped()
        } else if let a = spec.aspect {
            guard let ratio = parseAspect(a) else { throw JobError.invalid("aspect must look like \"16:9\" or \"1.5\"") }
            p.crop = .centered(aspect: ratio, in: source.size)
        }

        if let e = spec.effect {
            guard let effect = ColorEffect(rawValue: e.lowercased()) else {
                throw JobError.invalid("effect must be one of: \(ColorEffect.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            p.adjustments.effect = effect
        }
        if let v = spec.brightness { p.adjustments.brightness = min(max(v, -1), 1) }
        if let v = spec.contrast { p.adjustments.contrast = min(max(v, 0.25), 4) }
        if let v = spec.saturation { p.adjustments.saturation = min(max(v, 0), 3) }

        p.texts = try (spec.texts ?? []).map { t in
            var o = TextOverlay(text: t.text)
            switch (t.position ?? "bottom").lowercased() {
            case "top": o.position = NormalizedPoint(x: 0.5, y: 0.13)
            case "center", "middle": o.position = NormalizedPoint(x: 0.5, y: 0.5)
            case "bottom": o.position = NormalizedPoint(x: 0.5, y: 0.87)
            default: throw JobError.invalid("text position must be top, center or bottom")
            }
            if let s = t.size { o.fontSize = min(max(s, 0.02), 0.5) }
            if let c = t.color { o.color = try parseColor(c) }
            if let c = t.strokeColor { o.strokeColor = try parseColor(c) }
            if let f = t.font { o.fontName = f }
            // Non-Latin text renders better with a CJK-capable default font.
            if t.font == nil, t.text.unicodeScalars.contains(where: { $0.value > 0x2E80 }) {
                o.fontName = "PingFangSC-Semibold"
            }
            o.startTime = t.start
            o.endTime = t.end
            return o
        }
        return p
    }

    public static func estimate(_ spec: JobSpec) async throws -> JobEstimate {
        let source = try await open(spec)
        var project = try project(spec, source: source)
        if let kb = spec.targetSizeKB {
            project.settings.width = try await Exporter.fitWidth(project: project, source: source,
                                                                 targetBytes: Int64(kb) * 1024).width
        }
        let e = try await Exporter.estimateSize(project: project, source: source)
        let plan = FramePlanner.plan(project: project, source: source)
        let size = project.outputSize(sourceSize: source.size)
        return JobEstimate(width: Int(size.width), height: Int(size.height), frames: e.frames,
                           duration: (FramePlanner.totalDuration(plan) * 100).rounded() / 100,
                           estimatedBytes: e.bytes)
    }

    public static func run(_ spec: JobSpec,
                           progress: @escaping @Sendable (ExportProgress) -> Void = { _ in }) async throws -> JobResult {
        let began = Date()
        let source = try await open(spec)
        var project = try project(spec, source: source)
        if let kb = spec.targetSizeKB {
            project.settings.width = try await Exporter.fitWidth(project: project, source: source,
                                                                 targetBytes: Int64(kb) * 1024).width
        }
        let output = try spec.output.map { try outputURL($0) } ?? source.url.deletingPathExtension().appendingPathExtension("gif")
        try validateOutput(output, inputs: spec.inputs.map(expand))
        guard output.pathExtension.lowercased() == "gif" else {
            throw JobError.invalid("output must have a .gif extension")
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let r = try await Exporter.export(project: project, source: source, to: output, progress: progress)
        return JobResult(output: r.url.path, width: Int(r.size.width), height: Int(r.size.height),
                         frames: r.frameCount, duration: (r.duration * 100).rounded() / 100,
                         sizeBytes: r.fileSize, elapsedSeconds: (Date().timeIntervalSince(began) * 100).rounded() / 100)
    }

    /// Writes a single frame (with all edits applied) as PNG — lets agents "look" before encoding.
    public static func snapshot(_ spec: JobSpec, at time: Double?, to url: URL) async throws -> (width: Int, height: Int) {
        let source = try await open(spec)
        let project = try project(spec, source: source)
        try requireFinite([("at", time)])
        try validateOutput(url, inputs: spec.inputs.map(expand))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let t = time ?? (project.trimStart + project.trimEnd) / 2
        let cg = try await source.image(at: t)
        let compositor = Compositor(project: project, sourceSize: source.size)
        guard let rendered = compositor.renderImage(.init(cgImage: cg), time: t),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw JobError.invalid("无法写入截图：\(url.path)")
        }
        CGImageDestinationAddImage(dest, rendered, nil)
        guard CGImageDestinationFinalize(dest) else { throw JobError.invalid("无法写入截图：\(url.path)") }
        return (rendered.width, rendered.height)
    }

    // MARK: - Output validation

    /// Expands an output path; an empty path would otherwise resolve to the working directory.
    static func outputURL(_ path: String) throws -> URL {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw JobError.invalid("output path must not be empty")
        }
        return expand(path)
    }

    /// Rejects directories and any output that is the same file as one of the inputs
    /// (case-insensitive paths, symlinks and hard links included).
    static func validateOutput(_ output: URL, inputs: [URL]) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: output.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw JobError.invalid("output path is a directory: \(output.path)")
        }
        for input in inputs where sameFile(output, input) {
            throw JobError.invalid("output must differ from the input file")
        }
    }

    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: a.path), fm.fileExists(atPath: b.path),
           let ia = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
           let ib = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
           ia.isEqual(ib) {
            return true
        }
        let pa = a.resolvingSymlinksInPath().standardizedFileURL.path
        let pb = b.resolvingSymlinksInPath().standardizedFileURL.path
        return pa.caseInsensitiveCompare(pb) == .orderedSame
    }

    // MARK: - Parsing helpers

    static func clamp(_ v: Int) -> Int { min(max(v, 1), 100) }

    static func parseAspect(_ s: String) -> Double? {
        let parts = s.split(whereSeparator: { $0 == ":" || $0 == "/" || $0 == "x" }).compactMap { Double($0) }
        if parts.count == 2, parts[0] > 0, parts[1] > 0 { return parts[0] / parts[1] }
        if parts.count == 1, parts[0] > 0 { return parts[0] }
        return nil
    }

    static func parseColor(_ s: String) throws -> RGBAColor {
        let named: [String: RGBAColor] = ["white": .white, "black": .black, "yellow": .yellow,
                                          "red": RGBAColor(r: 1, g: 0.2, b: 0.2), "green": RGBAColor(r: 0.2, g: 0.85, b: 0.3),
                                          "blue": RGBAColor(r: 0.2, g: 0.5, b: 1)]
        if let c = named[s.lowercased()] { return c }
        var hex = s.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else {
            throw JobError.invalid("color must be a name or hex like #FFCC00")
        }
        if hex.count == 6 {
            return RGBAColor(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
        }
        return RGBAColor(r: Double((v >> 24) & 0xFF) / 255, g: Double((v >> 16) & 0xFF) / 255,
                         b: Double((v >> 8) & 0xFF) / 255, a: Double(v & 0xFF) / 255)
    }
}
