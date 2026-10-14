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

    @Test func presentationTimesStartAtZero() {
        let frames = [PlannedFrame(sourceTime: 1, delay: 0.1), PlannedFrame(sourceTime: 2, delay: 0.2)]
        #expect(FramePlanner.presentationTimes(frames) == [0, 0.1])
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
