import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import GifTrimCore

/// Shared synthetic test video (generated once).
enum Fixtures {
    /// Generated once; async so it never blocks the cooperative thread pool.
    static var video: URL {
        get async throws { try await VideoFixture.shared.url() }
    }

    static func tempGIF() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("giftrim-test-\(UUID().uuidString).gif")
    }

    /// Reads frame count, per-frame delays and size from a GIF file.
    static func inspect(_ url: URL) -> (count: Int, delays: [Double], size: CGSize, first: CGImage?) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return (0, [], .zero, nil) }
        let n = CGImageSourceGetCount(src)
        let delays = (0..<n).map { MediaSource.frameDelay(src: src, index: $0) }
        let first = CGImageSourceCreateImageAtIndex(src, 0, nil)
        return (n, delays, CGSize(width: first?.width ?? 0, height: first?.height ?? 0), first)
    }

    /// RGBA of a pixel (top-left origin).
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }
}

actor VideoFixture {
    static let shared = VideoFixture()
    private var task: Task<URL, Error>?

    func url() async throws -> URL {
        if let task { return try await task.value }
        let t = Task {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("giftrim-test-\(ProcessInfo.processInfo.processIdentifier).mp4")
            try await TestVideoGenerator.make(url: url, width: 320, height: 180, fps: 30, seconds: 2)
            return url
        }
        task = t
        return try await t.value
    }
}

@Suite struct FramePlannerTests {
    @Test func delaysAreQuantizedAndPreserveDuration() {
        let frames = (0..<30).map { PlannedFrame(sourceTime: Double($0) / 30, delay: 1.0 / 30) }
        let q = FramePlanner.quantizeDelays(frames)
        for f in q {
            #expect(abs(f.delay * 100 - (f.delay * 100).rounded()) < 1e-9)
            #expect(f.delay >= FramePlanner.minDelay - 1e-9)
        }
        #expect(abs(FramePlanner.totalDuration(q) - 1.0) < 0.011)
    }

    @Test func presentationTimesOffsetByLastDelay() {
        let frames = [PlannedFrame(sourceTime: 1, delay: 0.1), PlannedFrame(sourceTime: 2, delay: 0.2)]
        // gifski treats a first PTS > 0 as the last frame's delay, so all PTS are offset by it.
        let pts = FramePlanner.presentationTimes(frames)
        #expect(pts.count == 2 && abs(pts[0] - 0.2) < 1e-9 && abs(pts[1] - 0.3) < 1e-9)
    }

    @Test func planRespectsTrimFpsSpeedAndModes() async throws {
        let source = try await MediaSource.open(urls: [try await Fixtures.video])
        var p = Project(sourceURL: source.url, trimStart: 0.5, trimEnd: 1.5)
        p.settings.fps = 10
        let forward = FramePlanner.plan(project: p, source: source)
        #expect(forward.count == 10)
        #expect(abs(forward[0].sourceTime - 0.5) < 1e-9)
        #expect(forward.allSatisfy { $0.sourceTime >= 0.5 && $0.sourceTime < 1.5 })

        p.settings.speed = 2
        #expect(FramePlanner.plan(project: p, source: source).count == 5)
        p.settings.speed = 1

        p.settings.playbackMode = .reverse
        let reverse = FramePlanner.plan(project: p, source: source)
        #expect(reverse.map(\.sourceTime) == forward.map(\.sourceTime).reversed())

        p.settings.playbackMode = .bounce
        let bounce = FramePlanner.plan(project: p, source: source)
        #expect(bounce.count == 10 + 8)
        #expect(bounce[10].sourceTime == forward[8].sourceTime)

        p.customFrames = [FrameEdit(sourceTime: 0.2, delay: 0.5), FrameEdit(sourceTime: 0.1, delay: 0.001)]
        let custom = FramePlanner.plan(project: p, source: source)
        #expect(custom.map(\.sourceTime) == [0.2, 0.1])
        #expect(custom[1].delay == FramePlanner.minDelay)
    }
}

@Suite struct GeometryTests {
    @Test func outputSizeFollowsCropAndNeverUpscales() {
        let src = CGSize(width: 640, height: 360)
        #expect(Project.outputSize(sourceSize: src, crop: .full, width: 320) == CGSize(width: 320, height: 180))
        #expect(Project.outputSize(sourceSize: src, crop: .full, width: 4000) == CGSize(width: 640, height: 360))
        let half = NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)
        #expect(Project.outputSize(sourceSize: src, crop: half, width: 160) == CGSize(width: 160, height: 180))
    }

    @Test func clampKeepsRectInside() {
        let r = NormalizedRect(x: 0.9, y: -0.2, width: 0.5, height: 2).clamped()
        #expect(r.x + r.width <= 1 + 1e-9)
        #expect(r.y >= 0 && r.height <= 1)
    }

    @Test func centeredAspect() {
        let r = NormalizedRect.centered(aspect: 1, in: CGSize(width: 200, height: 100))
        let px = r.pixelRect(in: CGSize(width: 200, height: 100))
        #expect(px.width == 100 && px.height == 100 && px.minX == 50)
    }

    @Test func pixelRectStaysInsideAtEdges() {
        let size = CGSize(width: 200, height: 100)
        let edge = NormalizedRect(x: 1, y: 1, width: 0.001, height: 0.001).pixelRect(in: size)
        #expect(edge.width >= 1 && edge.height >= 1)
        #expect(edge.maxX <= size.width && edge.maxY <= size.height)
        let beyond = NormalizedRect(x: 1.5, y: -1, width: 0.5, height: 0.5).pixelRect(in: size)
        #expect(beyond.width >= 1 && beyond.height >= 1)
        #expect(beyond.minX >= 0 && beyond.maxX <= size.width && beyond.minY >= 0 && beyond.maxY <= size.height)
    }

    @Test func textLinesTreatCRLFAsOneBreak() {
        let t = TextOverlay(text: "a\r\nb")
        let one = Compositor.textBounds(TextOverlay(text: "a\nb"), size: CGSize(width: 400, height: 200))
        let crlf = Compositor.textBounds(t, size: CGSize(width: 400, height: 200))
        #expect(abs(one.height - crlf.height) < 1e-9)
    }

    @Test func textBoundsUseTopLeftOrigin() {
        var t = TextOverlay(text: "Hello")
        t.position = NormalizedPoint(x: 0.5, y: 0.85)
        let b = Compositor.textBounds(t, size: CGSize(width: 400, height: 200))
        #expect(abs((b.y + b.height / 2) - 0.85) < 0.01)
        #expect(abs((b.x + b.width / 2) - 0.5) < 0.01)
    }
}

@Suite(.serialized) struct ExportTests {
    @Test func exportsVideoWithCorrectOrientationAndTiming() async throws {
        let source = try await MediaSource.open(urls: [try await Fixtures.video])
        var p = Project(sourceURL: source.url, trimStart: 0, trimEnd: 1)
        p.settings.width = 160
        p.settings.fps = 10
        let out = Fixtures.tempGIF()
        defer { try? FileManager.default.removeItem(at: out) }
        let result = try await Exporter.export(project: p, source: source, to: out)
        #expect(result.frameCount == 10)
        let info = Fixtures.inspect(out)
        #expect(info.count == 10)
        #expect(info.size == CGSize(width: 160, height: 90))
        #expect(abs(info.delays.reduce(0, +) - 1.0) < 0.02)
        // Test video draws a red marker in the top-left corner.
        let px = Fixtures.pixel(try #require(info.first), x: 4, y: 4)
        #expect(px.r > 180 && px.g < 80 && px.b < 80, "top-left should be red, got \(px)")
    }

    @Test func textOverlayIsDrawnAtBottom() async throws {
        let source = try await MediaSource.open(urls: [try await Fixtures.video])
        var p = Project(sourceURL: source.url, trimStart: 0, trimEnd: 0.2)
        p.settings.width = 320
        p.settings.fps = 10
        var text = TextOverlay(text: "████")
        text.color = RGBAColor(r: 0, g: 1, b: 0)
        text.strokeWidth = 0
        text.position = NormalizedPoint(x: 0.5, y: 0.8)
        p.texts = [text]
        let out = Fixtures.tempGIF()
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try await Exporter.export(project: p, source: source, to: out)
        let img = try #require(Fixtures.inspect(out).first)
        let bottom = Fixtures.pixel(img, x: 160, y: Int(0.8 * 180))
        #expect(bottom.g > 180 && bottom.r < 100, "text should be green at the bottom, got \(bottom)")
        let mirrored = Fixtures.pixel(img, x: 160, y: Int(0.2 * 180))
        #expect(!(mirrored.g > 180 && mirrored.r < 100), "text must not be vertically flipped")
    }

    @Test func bounceAndGifInput() async throws {
        let source = try await MediaSource.open(urls: [try await Fixtures.video])
        var p = Project(sourceURL: source.url, trimStart: 0, trimEnd: 1)
        p.settings.width = 120
        p.settings.fps = 10
        p.settings.playbackMode = .bounce
        let out = Fixtures.tempGIF()
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try await Exporter.export(project: p, source: source, to: out)
        #expect(r.frameCount == 18)

        // Re-open the GIF as a source and keep native timing.
        let gif = try await MediaSource.open(urls: [out])
        #expect(gif.kind == .animatedImage)
        #expect(gif.nativeFrameTimes?.count == 18)
        var p2 = Project(sourceURL: gif.url, trimStart: 0, trimEnd: gif.duration)
        p2.settings.width = 120
        p2.settings.speed = 2
        let out2 = Fixtures.tempGIF()
        defer { try? FileManager.default.removeItem(at: out2) }
        let r2 = try await Exporter.export(project: p2, source: gif, to: out2)
        #expect(r2.frameCount == 18)
        #expect(abs(r2.duration - gif.duration / 2) < 0.1)
    }

    @Test func estimateIsInTheRightBallpark() async throws {
        let source = try await MediaSource.open(urls: [try await Fixtures.video])
        var p = Project(sourceURL: source.url, trimStart: 0, trimEnd: 2)
        p.settings.width = 160
        p.settings.fps = 10
        let est = try await Exporter.estimateSize(project: p, source: source)
        let out = Fixtures.tempGIF()
        defer { try? FileManager.default.removeItem(at: out) }
        let actual = try await Exporter.export(project: p, source: source, to: out).fileSize
        let ratio = Double(est.bytes) / Double(actual)
        #expect(ratio > 0.5 && ratio < 2, "estimate \(est.bytes) vs actual \(actual)")
    }

    /// Writes a GIF whose frames have the given delays (seconds).
    static func writeGIF(_ url: URL, delays: [Double]) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, delays.count, nil))
        for (i, d) in delays.enumerated() {
            var data = [UInt8](repeating: UInt8(40 * i), count: 16 * 16 * 4)
            let ctx = try #require(CGContext(data: &data, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(srgbRed: Double(i) / 3, green: 0.5, blue: 0.2, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            let image = try #require(ctx.makeImage())
            let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: d]] as CFDictionary
            CGImageDestinationAddImage(dest, image, props)
        }
        #expect(CGImageDestinationFinalize(dest))
    }

    /// Per-frame unclamped delays as stored in the file.
    static func rawDelays(_ url: URL) -> [Double] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        return (0..<CGImageSourceGetCount(src)).map { i in
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? 0
        }
    }

    @Test func lastFrameDelayIsPreserved() async throws {
        let input = Fixtures.tempGIF()
        let out = Fixtures.tempGIF()
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: out) }
        try Self.writeGIF(input, delays: [1.0, 1.0, 1.5])
        let source = try await MediaSource.open(urls: [input])
        var p = Project(sourceURL: input, trimStart: 0, trimEnd: source.duration)
        p.settings.width = 16
        _ = try await Exporter.export(project: p, source: source, to: out)
        let delays = Self.rawDelays(out)
        #expect(delays.count == 3)
        #expect(zip(delays, [1.0, 1.0, 1.5]).allSatisfy { abs($0 - $1) < 0.011 }, "got \(delays)")
    }

    @Test func singleImageKeepsPlannedDuration() async throws {
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("giftrim-test-\(UUID().uuidString).png")
        let out = Fixtures.tempGIF()
        defer { try? FileManager.default.removeItem(at: png); try? FileManager.default.removeItem(at: out) }
        let ctx = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let dest = try #require(CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
        #expect(CGImageDestinationFinalize(dest))

        var spec = JobSpec(inputs: [png.path])
        spec.output = out.path
        spec.width = 16
        _ = try await JobRunner.run(spec)
        let delays = Self.rawDelays(out)
        #expect(delays.count == 1 && abs(delays[0] - 0.5) < 0.011, "got \(delays)")
    }

    @Test func directoryOutputIsRejectedWithoutDeletion() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("giftrim-test-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keep = dir.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: keep)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try await Fixtures.video

        var spec = JobSpec(inputs: [video.path])
        spec.output = dir.path
        spec.end = 0.3
        await #expect(throws: (any Error).self) { try await JobRunner.run(spec) }
        #expect(FileManager.default.fileExists(atPath: keep.path))

        // Exporter itself must never remove a directory either.
        let source = try await MediaSource.open(urls: [video])
        let p = Project(sourceURL: video, trimStart: 0, trimEnd: 0.3)
        await #expect(throws: (any Error).self) { try await Exporter.export(project: p, source: source, to: dir) }
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }

    @Test func failedExportKeepsExistingOutput() async throws {
        let out = Fixtures.tempGIF()
        defer { try? FileManager.default.removeItem(at: out) }
        try Data("old".utf8).write(to: out)
        let source = try await MediaSource.open(urls: [try await Fixtures.video])
        var p = Project(sourceURL: source.url, trimStart: 0, trimEnd: 2)
        p.settings.width = 320
        p.settings.fps = 30
        let task = Task { try await Exporter.export(project: p, source: source, to: out) }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(try Data(contentsOf: out) == Data("old".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: out.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".giftrim-") && $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func cancellationStopsExport() async throws {
        let source = try await MediaSource.open(urls: [try await Fixtures.video])
        var p = Project(sourceURL: source.url, trimStart: 0, trimEnd: 2)
        p.settings.width = 320
        p.settings.fps = 30
        let out = Fixtures.tempGIF()
        let task = Task { try await Exporter.export(project: p, source: source, to: out) }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }
}

@Suite struct JobSpecTests {
    @Test func validatesAndBuildsProject() async throws {
        let source = try await MediaSource.open(urls: [try await Fixtures.video])
        var spec = JobSpec(inputs: [try await Fixtures.video.path])
        spec.aspect = "1:1"
        spec.mode = "bounce"
        spec.texts = [JobSpec.TextSpec(text: "你好")]
        let p = try JobRunner.project(spec, source: source)
        let px = p.crop.pixelRect(in: source.size)
        #expect(px.width == px.height)
        #expect(p.settings.playbackMode == .bounce)
        #expect(p.texts.first?.fontName == "PingFangSC-Semibold")

        spec.mode = "sideways"
        #expect(throws: JobError.self) { try JobRunner.project(spec, source: source) }
        spec.mode = nil
        spec.start = 5
        #expect(throws: JobError.self) { try JobRunner.project(spec, source: source) }
    }

    @Test func rejectsInvalidNumbers() async throws {
        let source = try await MediaSource.open(urls: [try await Fixtures.video])
        var spec = JobSpec(inputs: [try await Fixtures.video.path])
        spec.width = 0
        #expect(throws: JobError.self) { try JobRunner.project(spec, source: source) }
        spec.width = nil
        spec.targetSizeKB = 0
        #expect(throws: JobError.self) { try JobRunner.project(spec, source: source) }
        spec.targetSizeKB = nil
        spec.crop = JobSpec.PixelRect(x: 0, y: 0, width: 0, height: 10)
        #expect(throws: JobError.self) { try JobRunner.project(spec, source: source) }
        spec.crop = nil
        spec.fps = .nan
        #expect(throws: JobError.self) { try JobRunner.project(spec, source: source) }
        spec.fps = nil
        spec.brightness = .infinity
        #expect(throws: JobError.self) { try JobRunner.project(spec, source: source) }
    }

    @Test func rejectsOutputSameAsInputIgnoringCase() async throws {
        let video = try await Fixtures.video
        var spec = JobSpec(inputs: [video.path])
        spec.output = video.path.uppercased()
        spec.end = 0.3
        await #expect(throws: JobError.self) { try await JobRunner.run(spec) }
        #expect(FileManager.default.fileExists(atPath: video.path))
        // Snapshot shares the check.
        await #expect(throws: JobError.self) { try await JobRunner.snapshot(spec, at: 0.1, to: video) }
        #expect(FileManager.default.fileExists(atPath: video.path))
    }

    @Test func parsesColorsAndAspects() throws {
        #expect(try JobRunner.parseColor("#FF0000") == RGBAColor(r: 1, g: 0, b: 0))
        #expect(try JobRunner.parseColor("white") == .white)
        #expect(throws: JobError.self) { try JobRunner.parseColor("#12") }
        #expect(JobRunner.parseAspect("16:9") == 16.0 / 9)
        #expect(JobRunner.parseAspect("2") == 2)
        #expect(JobRunner.parseAspect("abc") == nil)
    }

    @Test func runsFromJSON() async throws {
        let out = Fixtures.tempGIF()
        defer { try? FileManager.default.removeItem(at: out) }
        let video = try await Fixtures.video
        let json = #"{"inputs":["\#(video.path)"],"output":"\#(out.path)","width":100,"end":0.5,"fps":10}"#
        let spec = try JSONDecoder().decode(JobSpec.self, from: Data(json.utf8))
        let r = try await JobRunner.run(spec)
        #expect(r.width == 100 && r.frames == 5)
        #expect(FileManager.default.fileExists(atPath: out.path))
    }
}
