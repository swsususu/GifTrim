import AppKit
import AVFoundation
import CoreImage
import GifTrimCore
import Observation

enum InspectorTab: String, CaseIterable, Identifiable {
    case output, crop, text, image, filter, frames
    var id: String { rawValue }
    var title: String {
        switch self {
        case .output: return "输出"
        case .crop: return "裁剪"
        case .text: return "文字"
        case .image: return "贴图"
        case .filter: return "滤镜"
        case .frames: return "帧"
        }
    }
    var symbol: String {
        switch self {
        case .output: return "slider.horizontal.3"
        case .crop: return "crop"
        case .text: return "character.textbox"
        case .image: return "photo.on.rectangle"
        case .filter: return "camera.filters"
        case .frames: return "film.stack"
        }
    }
}

/// Thread-safe holder for the compositor used by the AVPlayer video composition handler.
final class CompositorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Compositor?
    func set(_ c: Compositor) { lock.lock(); value = c; lock.unlock() }
    func get() -> Compositor? { lock.lock(); defer { lock.unlock() }; return value }
}

/// State for editing one source.
@MainActor
@Observable
final class EditorModel {
    let source: MediaSource
    var project: Project

    var currentTime: Double = 0
    var isPlaying = false
    var thumbnails: [CGImage] = []
    /// Adjusted still frame for image-based sources (video uses `player`).
    var displayFrame: CGImage?

    var inspectorTab: InspectorTab = .output
    var selectedTextID: UUID?
    var selectedImageID: UUID?
    var focusTextEditor = false
    /// Locked crop aspect ratio (pixel width / height), nil = free.
    var cropAspect: Double?

    var showExport = false
    var estimate: (bytes: Int64, frames: Int)?
    var isEstimating = false

    var frameThumbs: [Double: CGImage] = [:]

    @ObservationIgnored let player: AVPlayer?
    @ObservationIgnored private let compositorBox = CompositorBox()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var playTimer: Timer?
    @ObservationIgnored private var estimateTask: Task<Void, Never>?
    @ObservationIgnored private var frameTask: Task<Void, Never>?
    @ObservationIgnored private var lastAdjustments: Adjustments
    @ObservationIgnored private var loadingThumbs = Set<Double>()

    init(source: MediaSource) {
        self.source = source
        var p = Project(sourceURL: source.url, trimStart: 0, trimEnd: source.duration)
        p.settings.width = min(AppSettings.defaultWidth, Int(source.size.width))
        p.settings.fps = AppSettings.defaultFPS
        p.settings.quality = AppSettings.defaultQuality
        // Short clips from image sources default to native timing; keep fps sensible for video.
        if source.kind == .video, source.nominalFrameRate > 0 {
            p.settings.fps = min(p.settings.fps, source.nominalFrameRate)
        }
        project = p
        lastAdjustments = p.adjustments

        if source.kind == .video {
            let item = AVPlayerItem(url: source.url)
            player = AVPlayer(playerItem: item)
            player?.actionAtItemEnd = .pause
        } else {
            player = nil
        }
        compositorBox.set(Self.previewCompositor(for: p, source: source))
        configurePlayer()
        Task { await loadThumbnails() }
        refreshDisplayFrame()
        scheduleEstimate()
    }

    func teardown() {
        pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        estimateTask?.cancel()
        frameTask?.cancel()
        player?.replaceCurrentItem(with: nil)
    }

    // MARK: - Derived

    var outputSize: CGSize { project.outputSize(sourceSize: source.size) }
    var trimDuration: Double { max(0, project.trimEnd - project.trimStart) }
    var isFrameEditing: Bool { project.customFrames != nil }

    var plannedFrames: [PlannedFrame] { FramePlanner.plan(project: project, source: source) }

    var frameStep: Double {
        if source.isDiscrete, let times = source.nativeFrameTimes, times.count > 1 {
            return source.duration / Double(times.count)
        }
        return 1 / max(1, source.nominalFrameRate)
    }

    // MARK: - Change handling

    /// Compositor that only applies adjustments to the full source frame (crop/overlays are drawn by the canvas).
    static func previewCompositor(for project: Project, source: MediaSource) -> Compositor {
        var p = project
        p.crop = .full
        p.texts = []
        p.images = []
        return Compositor(project: p, sourceSize: source.size, outputSize: source.size)
    }

    func projectDidChange() {
        if project.adjustments != lastAdjustments {
            lastAdjustments = project.adjustments
            compositorBox.set(Self.previewCompositor(for: project, source: source))
            refreshDisplayFrame()
            if let player, !isPlaying {
                // Force the paused frame to re-render with the new filters.
                player.currentItem?.videoComposition = makeVideoComposition()
                seek(to: currentTime)
            }
        }
        // Keep trim sane.
        if project.trimEnd > source.duration { project.trimEnd = source.duration }
        if project.trimStart < 0 { project.trimStart = 0 }
        if project.trimEnd < project.trimStart { project.trimEnd = project.trimStart }
        scheduleEstimate()
    }

    // MARK: - Player

    private func makeVideoComposition() -> AVVideoComposition? {
        guard let asset = player?.currentItem?.asset else { return nil }
        let box = compositorBox
        return AVVideoComposition(asset: asset) { request in
            let input = request.sourceImage
            let out = box.get()?.process(input) ?? input
            request.finish(with: out, context: nil)
        }
    }

    private func configurePlayer() {
        guard let player else { return }
        player.currentItem?.videoComposition = makeVideoComposition()
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                self?.playerTick(t.seconds)
            }
        }
    }

    private func playerTick(_ t: Double) {
        guard t.isFinite else { return }
        guard isPlaying else { return }
        currentTime = t
        let end = project.trimEnd
        if t >= end - 0.001 || (player?.rate == 0 && t >= source.duration - 0.05) {
            seek(to: project.trimStart)
            player?.playImmediately(atRate: previewRate)
        }
    }

    /// AVPlayer preview rate (clamped to what it plays smoothly).
    private var previewRate: Float { Float(max(0.1, min(project.settings.speed, 2))) }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        if currentTime < project.trimStart || currentTime >= project.trimEnd - 0.01 {
            seek(to: project.trimStart)
        }
        isPlaying = true
        if let player {
            player.playImmediately(atRate: previewRate)
        } else {
            var last = Date()
            playTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = Date()
                    var t = self.currentTime + now.timeIntervalSince(last) * self.project.settings.speed
                    last = now
                    if t >= self.project.trimEnd { t = self.project.trimStart }
                    self.setDiscreteTime(t)
                }
            }
        }
    }

    func pause() {
        isPlaying = false
        player?.pause()
        playTimer?.invalidate()
        playTimer = nil
    }

    func seek(to time: Double) {
        let t = max(0, min(time, source.duration))
        if let player {
            currentTime = t
            player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            setDiscreteTime(t)
        }
    }

    private func setDiscreteTime(_ t: Double) {
        let oldIndex = discreteIndex(currentTime)
        currentTime = t
        if discreteIndex(t) != oldIndex || displayFrame == nil { refreshDisplayFrame() }
    }

    private func discreteIndex(_ t: Double) -> Int {
        guard let times = source.nativeFrameTimes else { return 0 }
        return max(0, (times.lastIndex { $0 <= t + 1e-6 }) ?? 0)
    }

    func step(_ delta: Int) {
        pause()
        if source.isDiscrete, let times = source.nativeFrameTimes {
            let i = max(0, min(times.count - 1, discreteIndex(currentTime) + delta))
            seek(to: times[i])
        } else {
            seek(to: currentTime + Double(delta) * frameStep)
        }
    }

    func setTrimStartToCurrent() {
        project.trimStart = min(currentTime, project.trimEnd)
        projectDidChange()
    }

    func setTrimEndToCurrent() {
        project.trimEnd = max(currentTime, project.trimStart)
        projectDidChange()
    }

    private func refreshDisplayFrame() {
        guard source.isDiscrete else { return }
        let t = currentTime
        let compositor = compositorBox.get()
        let source = self.source
        frameTask?.cancel()
        frameTask = Task {
            guard let raw = try? await source.image(at: t) else { return }
            let image: CGImage?
            if let compositor, project.adjustments != Adjustments() {
                let ci = compositor.process(CIImage(cgImage: raw))
                image = PreviewContext.shared.createCGImage(ci, from: CGRect(origin: .zero, size: source.size))
            } else {
                image = raw
            }
            if !Task.isCancelled { displayFrame = image }
        }
    }

    // MARK: - Thumbnails

    private func loadThumbnails() async {
        thumbnails = await source.thumbnails(count: 24, maxDimension: 160)
    }

    func frameThumbnail(for time: Double) -> CGImage? {
        if let img = frameThumbs[time] { return img }
        guard !loadingThumbs.contains(time) else { return nil }
        loadingThumbs.insert(time)
        let source = self.source
        Task {
            if let img = try? await source.image(at: time, maxDimension: 140) {
                frameThumbs[time] = img
            }
        }
        return nil
    }

    // MARK: - Estimate

    func scheduleEstimate() {
        estimateTask?.cancel()
        isEstimating = true
        let project = self.project
        let source = self.source
        estimateTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            let result = try? await Exporter.estimateSize(project: project, source: source)
            guard !Task.isCancelled else { return }
            estimate = result
            isEstimating = false
        }
    }

    // MARK: - Overlays

    func addText() {
        var t = TextOverlay(text: "双击编辑文字")
        // Stack new texts upwards from the bottom.
        let offset = Double(project.texts.count) * 0.15
        t.position = NormalizedPoint(x: 0.5, y: max(0.1, 0.85 - offset))
        project.texts.append(t)
        selectedTextID = t.id
        inspectorTab = .text
        projectDidChange()
    }

    func removeText(_ id: UUID) {
        project.texts.removeAll { $0.id == id }
        if selectedTextID == id { selectedTextID = project.texts.last?.id }
        projectDidChange()
    }

    func addImage(url: URL) {
        guard let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { return }
        let overlay = ImageOverlay(imageData: data, name: url.lastPathComponent)
        project.images.append(overlay)
        selectedImageID = overlay.id
        inspectorTab = .image
        projectDidChange()
    }

    func removeImage(_ id: UUID) {
        project.images.removeAll { $0.id == id }
        if selectedImageID == id { selectedImageID = project.images.last?.id }
        projectDidChange()
    }

    // MARK: - Frame editing

    func beginFrameEditing() {
        project.customFrames = plannedFrames.map { FrameEdit(sourceTime: $0.sourceTime, delay: $0.delay) }
        projectDidChange()
    }

    func endFrameEditing() {
        project.customFrames = nil
        projectDidChange()
    }
}

enum PreviewContext {
    static let shared = CIContext(options: [.cacheIntermediates: false])
}
