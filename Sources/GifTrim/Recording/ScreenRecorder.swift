import AppKit
import AVFoundation
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case cancelled
    case permissionDenied
    case noDisplay
    case writer(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "已取消"
        case .permissionDenied:
            return "没有屏幕录制权限。请在“系统设置 › 隐私与安全性 › 屏幕与系统录音”中允许 GifTrim，然后重新打开应用。"
        case .noDisplay: return "找不到要录制的显示器"
        case .writer(let m): return "写入录像失败：\(m)"
        }
    }
}

/// Region selection + ScreenCaptureKit recording to a .mov file.
@MainActor
final class ScreenRecorder: NSObject {
    private var selectionWindows: [RegionSelectionWindow] = []
    private var controlPanel: RecordingControlPanel?
    private var frameWindow: NSWindow?
    private var stream: SCStream?
    private var output: StreamWriter?
    private var completion: ((Result<URL, Error>) -> Void)?
    private var keyMonitor: Any?

    var isBusy: Bool { completion != nil }

    func begin(completion: @escaping (Result<URL, Error>) -> Void) {
        guard !isBusy else { return }
        self.completion = completion
        if !CGPreflightScreenCaptureAccess() {
            // Triggers the system prompt the first time; afterwards the user must enable it in Settings.
            if !CGRequestScreenCaptureAccess() {
                finish(.failure(RecorderError.permissionDenied))
                return
            }
        }
        showSelection()
    }

    // MARK: - Selection

    private func showSelection() {
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let w = RegionSelectionWindow(screen: screen) { [weak self] rect in
                self?.selectionFinished(screen: screen, rect: rect)
            }
            w.orderFrontRegardless()
            selectionWindows.append(w)
        }
        selectionWindows.first { $0.screen == NSScreen.main }?.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { // esc
                self?.selectionFinished(screen: nil, rect: nil)
                return nil
            }
            return e
        }
    }

    private func closeSelection() {
        selectionWindows.forEach { $0.orderOut(nil) }
        selectionWindows.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// `rect` is in screen-local points with a top-left origin; nil rect with a screen = whole screen.
    private func selectionFinished(screen: NSScreen?, rect: CGRect?) {
        closeSelection()
        guard let screen else {
            finish(.failure(RecorderError.cancelled))
            return
        }
        let region = rect ?? CGRect(origin: .zero, size: screen.frame.size)
        Task { await startCapture(screen: screen, region: region) }
    }

    // MARK: - Capture

    private func startCapture(screen: NSScreen, region: CGRect) async {
        var writer: StreamWriter?
        do {
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                throw RecorderError.permissionDenied
            }
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                throw RecorderError.noDisplay
            }
            let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

            let scale = screen.backingScaleFactor
            let r = region.integral.intersection(CGRect(origin: .zero, size: screen.frame.size))
            let config = SCStreamConfiguration()
            config.sourceRect = r
            config.width = Self.even(r.width * scale)
            config.height = Self.even(r.height * scale)
            config.showsCursor = AppSettings.recordShowCursor
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, AppSettings.recordFPS)))
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 6
            config.colorSpaceName = CGColorSpace.sRGB
            config.capturesAudio = false

            let url = AppSettings.newRecordingURL(prefix: "屏幕录制")
            let w = try StreamWriter(url: url, width: config.width, height: config.height)
            writer = w
            // A capture error (display unplugged, permission revoked, ...) ends the recording like Stop.
            w.onError = { [weak self] in Task { @MainActor in await self?.stop() } }
            let stream = SCStream(filter: filter, configuration: config, delegate: w)
            try stream.addStreamOutput(w, type: .screen, sampleHandlerQueue: w.queue)
            try await stream.startCapture()
            self.stream = stream
            self.output = w
            showRecordingChrome(screen: screen, region: r)
        } catch {
            writer?.discard()
            finish(.failure(error))
        }
    }

    private static func even(_ v: CGFloat) -> Int {
        max(2, Int(v.rounded()) & ~1)
    }

    private func showRecordingChrome(screen: NSScreen, region: CGRect) {
        // Region in AppKit global coordinates (bottom-left origin).
        let sf = screen.frame
        let global = CGRect(x: sf.minX + region.minX, y: sf.maxY - region.maxY, width: region.width, height: region.height)

        let border = NSWindow(contentRect: global.insetBy(dx: -3, dy: -3), styleMask: .borderless, backing: .buffered, defer: false)
        border.isOpaque = false
        border.backgroundColor = .clear
        border.ignoresMouseEvents = true
        border.level = .statusBar
        border.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let v = NSView()
        v.wantsLayer = true
        v.layer?.borderColor = NSColor.systemRed.cgColor
        v.layer?.borderWidth = 2
        v.layer?.cornerRadius = 2
        border.contentView = v
        border.orderFrontRegardless()
        frameWindow = border

        let panel = RecordingControlPanel { [weak self] in
            Task { await self?.stop() }
        }
        // Place below the region when there's room, otherwise inside at the bottom.
        var origin = CGPoint(x: global.midX - panel.frame.width / 2, y: global.minY - panel.frame.height - 12)
        if origin.y < sf.minY + 8 { origin.y = global.minY + 12 }
        origin.x = min(max(origin.x, sf.minX + 8), sf.maxX - panel.frame.width - 8)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        controlPanel = panel
    }

    func stop() async {
        // Take ownership first so a second call (button + error callback) returns immediately.
        guard let stream, let output else { return }
        self.stream = nil
        self.output = nil
        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())
        controlPanel?.close()
        controlPanel = nil
        frameWindow?.orderOut(nil)
        frameWindow = nil
        try? await stream.stopCapture()
        do {
            let url = try await output.finish(stoppedAt: stopTime)
            NSApp.activate(ignoringOtherApps: true)
            finish(.success(url))
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        let c = completion
        completion = nil
        c?(result)
    }
}

/// Receives ScreenCaptureKit frames and writes them with AVAssetWriter (H.264).
final class StreamWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "giftrim.screen-writer")
    private let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var started = false
    private var firstPTS: CMTime = .invalid
    private var lastPTS: CMTime = .invalid
    private var finished = false
    private var failure: Error?
    /// Called on the main queue when the stream stops by itself with an error.
    var onError: (@Sendable () -> Void)?

    init(url: URL, width: Int, height: Int) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let bitrate = max(4_000_000, width * height * 8)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        super.init()
        guard writer.canAdd(input) else { throw RecorderError.writer("input") }
        writer.add(input)
        guard writer.startWriting() else { throw RecorderError.writer(writer.error?.localizedDescription ?? "start") }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, !finished else { return }
        // Only "complete" frames carry new pixels.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete else { return }
        let pts = sampleBuffer.presentationTimeStamp
        if !started {
            writer.startSession(atSourceTime: pts)
            firstPTS = pts
            started = true
        }
        if lastPTS.isValid, pts <= lastPTS { return }
        if input.isReadyForMoreMediaData {
            if input.append(sampleBuffer) { lastPTS = pts }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.failure = error }
        DispatchQueue.main.async { self.onError?() }
    }

    /// Cancels the writer and removes the (empty) output file.
    func discard() {
        queue.sync { finished = true }
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }

    /// `stoppedAt` is on the host clock, the same timeline as ScreenCaptureKit sample timestamps. Ending the
    /// session there (instead of at the last frame) keeps the still tail of a static screen.
    func finish(stoppedAt: CMTime) async throws -> URL {
        let (writer, input) = (self.writer, self.input)
        let hasFrames: Bool = queue.sync { lastPTS.isValid }
        guard hasFrames else {
            let reason = queue.sync { failure?.localizedDescription }
            discard()
            throw RecorderError.writer(reason ?? "没有录到任何画面")
        }
        queue.sync {
            finished = true
            input.markAsFinished()
            var end = max(lastPTS, stoppedAt)
            if end <= firstPTS { end = firstPTS + CMTime(value: 1, timescale: 10) }   // single frame: non-zero length
            writer.endSession(atSourceTime: end)
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw RecorderError.writer(writer.error?.localizedDescription ?? "unknown")
        }
        return url
    }
}

// MARK: - Region selection window

final class RegionSelectionWindow: NSWindow {
    init(screen: NSScreen, onFinish: @escaping (CGRect?) -> Void) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.onFinish = onFinish
        contentView = view
    }

    override var canBecomeKey: Bool { true }
}

final class RegionSelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var startPoint: CGPoint?
    private var current: CGRect?
    private var mouse: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        current = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = startPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        current = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
        mouse = p
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { startPoint = nil }
        guard let r = current, r.width >= 8, r.height >= 8 else {
            // A click (no drag) records the whole screen.
            onFinish?(nil)
            return
        }
        // Convert to top-left origin.
        onFinish?(CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        if let r = current {
            NSColor.clear.setFill()
            r.fill(using: .copy)
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
            path.lineWidth = 1
            path.stroke()
            let scale = window?.backingScaleFactor ?? 2
            drawLabel("\(Int(r.width * scale)) × \(Int(r.height * scale))", at: CGPoint(x: r.minX, y: r.maxY + 6))
        } else {
            let hint = "拖动选择录制区域 · 单击录制整个屏幕 · Esc 取消"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = (hint as NSString).size(withAttributes: attrs)
            let box = CGRect(x: bounds.midX - size.width / 2 - 16, y: bounds.midY - size.height / 2 - 10,
                             width: size.width + 32, height: size.height + 20)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
            (hint as NSString).draw(at: CGPoint(x: box.minX + 16, y: box.minY + 10), withAttributes: attrs)
        }
    }

    private func drawLabel(_ s: String, at p: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (s as NSString).size(withAttributes: attrs)
        var origin = p
        if origin.y + size.height + 6 > bounds.maxY { origin.y = p.y - size.height - 18 }
        let box = CGRect(x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        (s as NSString).draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attrs)
    }
}

// MARK: - Floating stop panel

final class RecordingControlPanel: NSPanel {
    private var timer: Timer?
    private let label = NSTextField(labelWithString: "0:00")
    private let began = Date()

    init(onStop: @escaping () -> Void) {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 190, height: 44),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isFloatingPanel = true
        isReleasedWhenClosed = false
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: 190, height: 44))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true

        let dot = NSView(frame: CGRect(x: 14, y: 17, width: 10, height: 10))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        bg.addSubview(dot)

        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        label.frame = CGRect(x: 32, y: 12, width: 60, height: 20)
        bg.addSubview(label)

        let button = ClosureButton(title: "停止录制", action: onStop)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.frame = CGRect(x: 92, y: 7, width: 88, height: 30)
        bg.addSubview(button)

        contentView = bg
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let s = Int(Date().timeIntervalSince(self.began))
            self.label.stringValue = String(format: "%d:%02d", s / 60, s % 60)
        }
    }

    override func close() {
        timer?.invalidate()
        super.close()
    }
}

final class ClosureButton: NSButton {
    private var handler: () -> Void = {}

    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        handler = action
        target = self
        self.action = #selector(fire)
    }

    @objc private func fire() { handler() }
}
