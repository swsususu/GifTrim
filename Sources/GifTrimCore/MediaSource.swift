import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum GifTrimError: LocalizedError {
    case unsupportedFile(String)
    case noVideoTrack
    case decodeFailed(String)
    case encodeFailed(String)
    case noFrames
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile(let name): return "不支持的文件：\(name)"
        case .noVideoTrack: return "文件中没有视频轨道"
        case .decodeFailed(let msg): return "解码失败：\(msg)"
        case .encodeFailed(let msg): return "GIF 编码失败：\(msg)"
        case .noFrames: return "没有可导出的帧，请检查截取范围"
        case .cancelled: return "已取消"
        }
    }
}

public enum SourceKind: String, Codable, Sendable {
    case video
    case animatedImage
    case imageSequence
}

/// A decoded frame of an image-based source.
struct DiscreteFrame: @unchecked Sendable {
    let image: CGImage
    let start: Double
    let duration: Double
}

/// Media that can be turned into a GIF: a video, an animated GIF/APNG/WebP, or a set of still images.
public final class MediaSource: @unchecked Sendable {
    public let urls: [URL]
    public let kind: SourceKind
    public let duration: Double
    /// Oriented pixel size.
    public let size: CGSize
    public let nominalFrameRate: Double
    /// For discrete sources: start time of every native frame.
    public let nativeFrameTimes: [Double]?

    let asset: AVAsset?
    let frames: [DiscreteFrame]

    public var url: URL { urls[0] }
    public var displayName: String {
        urls.count == 1 ? url.lastPathComponent : "\(urls.count) 张图片"
    }
    public var isDiscrete: Bool { kind != .video }

    public static let videoTypes: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
    public static let imageTypes: [UTType] = [.gif, .png, .jpeg, .heic, .webP, .tiff, .bmp, .image]

    private init(urls: [URL], kind: SourceKind, duration: Double, size: CGSize, fps: Double,
                 nativeFrameTimes: [Double]?, asset: AVAsset?, frames: [DiscreteFrame]) {
        self.urls = urls
        self.kind = kind
        self.duration = duration
        self.size = size
        self.nominalFrameRate = fps
        self.nativeFrameTimes = nativeFrameTimes
        self.asset = asset
        self.frames = frames
    }

    /// Opens one video, one animated image, or several still images (as a sequence).
    public static func open(urls: [URL], stillFrameDuration: Double = 0.5) async throws -> MediaSource {
        guard let first = urls.first else { throw GifTrimError.noFrames }
        if urls.count == 1 {
            let type = UTType(filenameExtension: first.pathExtension.lowercased())
            if let type, type.conforms(to: .image) {
                return try openImages(urls: urls, stillFrameDuration: stillFrameDuration)
            }
            return try await openVideo(url: first)
        }
        let images = urls.filter { UTType(filenameExtension: $0.pathExtension.lowercased())?.conforms(to: .image) == true }
        if images.isEmpty {
            return try await openVideo(url: first)
        }
        let sorted = images.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return try openImages(urls: sorted, stillFrameDuration: stillFrameDuration)
    }

    static func openVideo(url: URL) async throws -> MediaSource {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw GifTrimError.unsupportedFile(url.lastPathComponent)
        }
        guard let track = tracks.first else { throw GifTrimError.noVideoTrack }
        let (naturalSize, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let size = CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded())
        guard size.width > 0, size.height > 0, duration.isFinite, duration > 0 else {
            throw GifTrimError.unsupportedFile(url.lastPathComponent)
        }
        return MediaSource(urls: [url], kind: .video, duration: duration, size: size,
                           fps: fps > 0 ? Double(fps) : 30, nativeFrameTimes: nil, asset: asset, frames: [])
    }

    static func openImages(urls: [URL], stillFrameDuration: Double) throws -> MediaSource {
        var frames: [DiscreteFrame] = []
        var t = 0.0
        var animated = false
        for url in urls {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw GifTrimError.unsupportedFile(url.lastPathComponent)
            }
            let count = CGImageSourceGetCount(src)
            if count > 1 { animated = true }
            for i in 0..<count {
                let opts: [CFString: Any] = [
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                guard var image = CGImageSourceCreateImageAtIndex(src, i, opts as CFDictionary) else { continue }
                if count == 1, let oriented = orientedImage(src: src, image: image) {
                    image = oriented
                }
                let delay = count > 1 ? frameDelay(src: src, index: i) : stillFrameDuration
                frames.append(DiscreteFrame(image: image, start: t, duration: delay))
                t += delay
            }
        }
        guard let firstImage = frames.first?.image else {
            throw GifTrimError.unsupportedFile(urls.first?.lastPathComponent ?? "")
        }
        // Normalize sizes: every frame is drawn into the first frame's canvas (aspect-fit).
        let size = CGSize(width: firstImage.width, height: firstImage.height)
        let avg = frames.isEmpty ? 0.1 : t / Double(frames.count)
        return MediaSource(urls: urls, kind: animated && urls.count == 1 ? .animatedImage : .imageSequence,
                           duration: t, size: size, fps: avg > 0 ? 1 / avg : 10,
                           nativeFrameTimes: frames.map(\.start), asset: nil, frames: frames)
    }

    private static func orientedImage(src: CGImageSource, image: CGImage) -> CGImage? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let raw = props[kCGImagePropertyOrientation] as? UInt32, raw != 1,
              let orientation = CGImagePropertyOrientation(rawValue: raw) else { return nil }
        let ci = CIImage(cgImage: image).oriented(orientation)
        return SharedCIContext.shared.createCGImage(ci, from: ci.extent)
    }

    static func frameDelay(src: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] else { return 0.1 }
        let dictKeys: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (dictKey, unclamped, clamped) in dictKeys {
            if let dict = props[dictKey] as? [CFString: Any] {
                let value = (dict[unclamped] as? Double) ?? (dict[clamped] as? Double) ?? 0.1
                // Browsers treat delays below 20ms as 100ms.
                return value < 0.011 ? 0.1 : value
            }
        }
        return 0.1
    }

    // MARK: - Discrete frame access

    func discreteIndex(at time: Double) -> Int {
        guard !frames.isEmpty else { return 0 }
        var lo = 0
        var hi = frames.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if frames[mid].start <= time + 1e-6 { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// CIImage for a discrete frame, normalized to the source canvas size.
    func discreteImage(at time: Double) -> CIImage {
        let frame = frames[discreteIndex(at: time)]
        return Self.fit(CIImage(cgImage: frame.image), into: size)
    }

    static func fit(_ image: CIImage, into size: CGSize) -> CIImage {
        let ext = image.extent
        if abs(ext.width - size.width) < 0.5 && abs(ext.height - size.height) < 0.5 && ext.origin == .zero {
            return image
        }
        let scale = min(size.width / ext.width, size.height / ext.height)
        let scaled = image.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (size.width - ext.width * scale) / 2
        let dy = (size.height - ext.height * scale) / 2
        let placed = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        let background = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        return placed.composited(over: background).cropped(to: CGRect(origin: .zero, size: size))
    }

    // MARK: - Random access (thumbnails, still preview)

    /// Returns the frame displayed at `time` as an oriented CGImage, optionally downscaled.
    public func image(at time: Double, maxDimension: CGFloat? = nil) async throws -> CGImage {
        if isDiscrete {
            var ci = discreteImage(at: time)
            if let maxDimension {
                let scale = min(1, maxDimension / max(size.width, size.height))
                if scale < 1 { ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
            }
            guard let cg = SharedCIContext.shared.createCGImage(ci, from: ci.extent.integral) else {
                throw GifTrimError.decodeFailed("frame")
            }
            return cg
        }
        let generator = makeGenerator(maxDimension: maxDimension, exact: true)
        let cmTime = CMTime(seconds: max(0, min(time, duration)), preferredTimescale: 600)
        return try await generator.image(at: cmTime).image
    }

    public func makeGenerator(maxDimension: CGFloat?, exact: Bool) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset!)
        generator.appliesPreferredTrackTransform = true
        if exact {
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        } else {
            generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        }
        if let maxDimension {
            generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        }
        return generator
    }

    /// Thumbnails for evenly spaced times (fast, approximate for video).
    public func thumbnails(count: Int, maxDimension: CGFloat) async -> [CGImage] {
        guard count > 0 else { return [] }
        let times = (0..<count).map { duration * (Double($0) + 0.5) / Double(count) }
        if isDiscrete {
            var result: [CGImage] = []
            for t in times {
                if let img = try? await image(at: t, maxDimension: maxDimension) { result.append(img) }
            }
            return result
        }
        let generator = makeGenerator(maxDimension: maxDimension, exact: false)
        var result: [CGImage] = []
        for await item in generator.images(for: times.map { CMTime(seconds: $0, preferredTimescale: 600) }) {
            if let img = try? item.image { result.append(img) }
        }
        return result
    }
}

enum SharedCIContext {
    static let shared: CIContext = {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        return CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .outputColorSpace: srgb,
            .cacheIntermediates: false,
        ])
    }()
}
