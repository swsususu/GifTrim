import AVFoundation
import CoreImage
import Foundation

/// Produces source frames (as CIImage at source size) for a sorted list of source times.
enum FrameReader {
    /// Calls `body` once for every time in `sortedTimes` (ascending), in order.
    static func read(source: MediaSource, sortedTimes: [Double],
                     body: (Int, CIImage) throws -> Void) async throws {
        guard !sortedTimes.isEmpty else { return }
        if source.isDiscrete {
            for (i, t) in sortedTimes.enumerated() {
                try Task.checkCancellation()
                try autoreleasepool { try body(i, source.discreteImage(at: t)) }
            }
            return
        }
        do {
            try await readSequential(source: source, sortedTimes: sortedTimes, body: body)
        } catch let error as CancellationError {
            throw error
        } catch GifTrimError.cancelled {
            throw GifTrimError.cancelled
        } catch GifTrimError.encodeFailed(let msg) {
            throw GifTrimError.encodeFailed(msg)
        } catch {
            // Fall back to the slower random-access generator (e.g. for exotic codecs).
            try await readWithGenerator(source: source, sortedTimes: sortedTimes, body: body)
        }
    }

    private static func readSequential(source: MediaSource, sortedTimes: [Double],
                                       body: (Int, CIImage) throws -> Void) async throws {
        guard let asset = source.asset else { throw GifTrimError.noVideoTrack }
        let reader = try AVAssetReader(asset: asset)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let composition = try await AVVideoComposition.videoComposition(withPropertiesOf: asset)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: tracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw GifTrimError.decodeFailed("reader") }
        reader.add(output)
        let first = max(0, sortedTimes[0] - 1)
        let last = sortedTimes[sortedTimes.count - 1] + 1
        reader.timeRange = CMTimeRange(start: CMTime(seconds: first, preferredTimescale: 600),
                                       end: CMTime(seconds: min(last, source.duration + 1), preferredTimescale: 600))
        guard reader.startReading() else {
            throw GifTrimError.decodeFailed(reader.error?.localizedDescription ?? "reader")
        }
        defer { reader.cancelReading() }

        var current: CIImage?
        var pending: (CIImage, Double)?
        var exhausted = false
        let eps = 0.0005

        func nextSample() -> (CIImage, Double)? {
            guard !exhausted, let sample = output.copyNextSampleBuffer() else {
                exhausted = true
                return nil
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard let pixel = CMSampleBufferGetImageBuffer(sample) else { return nil }
            // Copy into an independent CIImage so the decoder can recycle its buffer.
            let image = CIImage(cvPixelBuffer: pixel)
            return (image, pts)
        }

        for (i, t) in sortedTimes.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                if pending == nil { pending = nextSample() }
                while let p = pending, p.1 <= t + eps {
                    current = p.0
                    pending = nextSample()
                }
                if current == nil, let p = pending {
                    // Requested time precedes the first decodable frame; use it.
                    current = p.0
                }
                guard let image = current else { throw GifTrimError.decodeFailed("no frame at \(t)") }
                try body(i, MediaSource.fit(image, into: source.size))
            }
        }
        if reader.status == .failed {
            throw GifTrimError.decodeFailed(reader.error?.localizedDescription ?? "reader")
        }
    }

    private static func readWithGenerator(source: MediaSource, sortedTimes: [Double],
                                          body: (Int, CIImage) throws -> Void) async throws {
        let generator = source.makeGenerator(maxDimension: nil, exact: true)
        for (i, t) in sortedTimes.enumerated() {
            try Task.checkCancellation()
            let cg = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            try autoreleasepool { try body(i, MediaSource.fit(CIImage(cgImage: cg), into: source.size)) }
        }
    }
}

public struct ExportProgress: Sendable {
    public var rendered: Int
    public var encoded: Int
    public var total: Int

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(rendered + encoded) / Double(2 * total))
    }
}

public struct ExportResult: Sendable {
    public var url: URL
    public var frameCount: Int
    public var duration: Double
    public var fileSize: Int64
    public var size: CGSize
}

/// Renders a project into a GIF file using gifski.
public enum Exporter {
    public static func export(project: Project, source: MediaSource, to url: URL,
                              frameLimit: Int? = nil,
                              progress: @escaping @Sendable (ExportProgress) -> Void = { _ in }) async throws -> ExportResult {
        var plan = FramePlanner.plan(project: project, source: source)
        if let frameLimit, plan.count > frameLimit {
            plan = Array(plan.prefix(frameLimit))
        }
        guard !plan.isEmpty else { throw GifTrimError.noFrames }

        let compositor = Compositor(project: project, sourceSize: source.size)
        let outSize = compositor.outputSize
        let width = Int(outSize.width)
        let height = Int(outSize.height)
        let total = plan.count

        var options = GifskiOptions()
        options.quality = project.settings.quality
        options.lossyQuality = project.settings.lossyQuality
        options.motionQuality = project.settings.motionQuality
        options.fast = project.settings.fast
        options.repeatCount = project.settings.repeatCount

        let state = ProgressState(total: total, report: progress)
        try? FileManager.default.removeItem(at: url)
        let encoder = try GifskiEncoder(outputURL: url, width: width, height: height, options: options) { encoded in
            state.update(encoded: encoded)
        }

        let pts = FramePlanner.presentationTimes(plan)
        // Unique source times, sorted, and mapping plan index -> unique index.
        let uniqueTimes = Array(Set(plan.map(\.sourceTime))).sorted()
        let indexOf = Dictionary(uniqueKeysWithValues: uniqueTimes.enumerated().map { ($1, $0) })
        let planUnique = plan.map { indexOf[$0.sourceTime]! }
        let monotonic = zip(planUnique, planUnique.dropFirst()).allSatisfy { $0 <= $1 }

        let buffer = RGBABuffer(width: width, height: height)

        do {
            try await withTaskCancellationHandler {
                if monotonic {
                    var planCursor = 0
                    try await FrameReader.read(source: source, sortedTimes: uniqueTimes) { u, image in
                        compositor.render(image, time: uniqueTimes[u], into: buffer)
                        while planCursor < plan.count, planUnique[planCursor] == u {
                            try encoder.addFrame(rgba: buffer.data, width: width, height: height,
                                                 bytesPerRow: buffer.bytesPerRow, pts: pts[planCursor])
                            planCursor += 1
                            state.update(rendered: planCursor)
                        }
                    }
                } else {
                    // Non-monotonic order (reverse, bounce, custom): render unique frames to a disk cache first.
                    let cache = try FrameCache(frameBytes: buffer.byteCount, count: uniqueTimes.count)
                    try await FrameReader.read(source: source, sortedTimes: uniqueTimes) { u, image in
                        compositor.render(image, time: uniqueTimes[u], into: buffer)
                        try cache.write(index: u, from: buffer.data)
                        state.update(rendered: Int(Double(u + 1) / Double(uniqueTimes.count) * Double(total) * 0.9))
                    }
                    for (i, u) in planUnique.enumerated() {
                        try Task.checkCancellation()
                        try cache.read(index: u, into: buffer.data)
                        try encoder.addFrame(rgba: buffer.data, width: width, height: height,
                                             bytesPerRow: buffer.bytesPerRow, pts: pts[i])
                        state.update(rendered: max(Int(Double(total) * 0.9), i + 1))
                    }
                }
            } onCancel: {
                encoder.cancel()
            }
            state.update(rendered: total)
            try await Task.detached(priority: .userInitiated) { try encoder.finish() }.value
        } catch {
            encoder.cancel()
            try? encoder.finish()
            try? FileManager.default.removeItem(at: url)
            if error is CancellationError { throw GifTrimError.cancelled }
            throw error
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return ExportResult(url: url, frameCount: plan.count, duration: FramePlanner.totalDuration(plan),
                            fileSize: fileSize, size: outSize)
    }

    /// Estimates final size by encoding a sample of frames.
    public static func estimateSize(project: Project, source: MediaSource) async throws -> (bytes: Int64, frames: Int) {
        let plan = FramePlanner.plan(project: project, source: source)
        guard !plan.isEmpty else { throw GifTrimError.noFrames }
        let sampleCount = min(plan.count, 24)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("giftrim-estimate-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Use a contiguous chunk from the middle: GIF compresses inter-frame deltas, so contiguity matters.
        var sampled = project
        let startIndex = max(0, (plan.count - sampleCount) / 2)
        sampled.customFrames = plan[startIndex..<(startIndex + sampleCount)].map {
            FrameEdit(sourceTime: $0.sourceTime, delay: $0.delay)
        }
        sampled.settings.playbackMode = .forward
        let result = try await export(project: sampled, source: source, to: tmp)
        let scaled = Double(result.fileSize) * Double(plan.count) / Double(sampleCount)
        return (Int64(scaled), plan.count)
    }

    /// Searches output width so the GIF fits `targetBytes`. Returns the chosen width and estimate.
    public static func fitWidth(project: Project, source: MediaSource, targetBytes: Int64,
                                minWidth: Int = 120) async throws -> (width: Int, bytes: Int64) {
        let maxWidth = Int(project.crop.clamped().pixelRect(in: source.size).width)
        var lo = minWidth
        var hi = max(minWidth, min(maxWidth, project.settings.width))
        var p = project
        p.settings.width = hi
        var best = try await estimateSize(project: p, source: source)
        if best.bytes <= targetBytes { return (hi, best.bytes) }
        var bestWidth = lo
        var bestBytes: Int64 = 0
        for _ in 0..<7 where hi - lo > 8 {
            try Task.checkCancellation()
            let mid = (lo + hi) / 2
            p.settings.width = mid
            best = try await estimateSize(project: p, source: source)
            if best.bytes <= targetBytes {
                bestWidth = mid
                bestBytes = best.bytes
                lo = mid
            } else {
                hi = mid
            }
        }
        if bestBytes == 0 {
            p.settings.width = lo
            bestBytes = try await estimateSize(project: p, source: source).bytes
        }
        return (bestWidth, bestBytes)
    }
}

final class ProgressState: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: ExportProgress
    private let report: @Sendable (ExportProgress) -> Void
    private var lastReport = Date.distantPast

    init(total: Int, report: @escaping @Sendable (ExportProgress) -> Void) {
        progress = ExportProgress(rendered: 0, encoded: 0, total: total)
        self.report = report
    }

    func update(rendered: Int? = nil, encoded: Int? = nil) {
        let snapshot: ExportProgress? = lock.withLock {
            if let rendered { progress.rendered = max(progress.rendered, min(rendered, progress.total)) }
            if let encoded { progress.encoded = max(progress.encoded, min(encoded, progress.total)) }
            let now = Date()
            let done = progress.encoded >= progress.total
            guard done || now.timeIntervalSince(lastReport) > 0.05 else { return nil }
            lastReport = now
            return progress
        }
        if let snapshot { report(snapshot) }
    }
}

/// Fixed-size raw frame storage in a temporary file.
final class FrameCache {
    let handle: FileHandle
    let url: URL
    let frameBytes: Int

    init(frameBytes: Int, count: Int) throws {
        self.frameBytes = frameBytes
        url = FileManager.default.temporaryDirectory.appendingPathComponent("giftrim-frames-\(UUID().uuidString).raw")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forUpdating: url)
        try handle.truncate(atOffset: UInt64(frameBytes * count))
    }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    func write(index: Int, from pointer: UnsafeRawPointer) throws {
        try handle.seek(toOffset: UInt64(index * frameBytes))
        try handle.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer), count: frameBytes, deallocator: .none))
    }

    func read(index: Int, into pointer: UnsafeMutableRawPointer) throws {
        try handle.seek(toOffset: UInt64(index * frameBytes))
        guard let data = try handle.read(upToCount: frameBytes), data.count == frameBytes else {
            throw GifTrimError.decodeFailed("frame cache")
        }
        data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: frameBytes)
    }
}
