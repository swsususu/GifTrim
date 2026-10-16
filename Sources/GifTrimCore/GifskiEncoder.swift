import CGifski
import CoreGraphics
import Foundation

/// Thread-safe progress/cancellation state shared with gifski's C callbacks.
final class EncoderContext: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    private var _processed = 0
    private var _errors: [String] = []
    let onFrameEncoded: @Sendable (Int) -> Void

    init(onFrameEncoded: @escaping @Sendable (Int) -> Void) {
        self.onFrameEncoded = onFrameEncoded
    }

    var cancelled: Bool {
        get { lock.withLock { _cancelled } }
        set { lock.withLock { _cancelled = newValue } }
    }

    func frameProcessed() -> Bool {
        let (count, cancelled) = lock.withLock { () -> (Int, Bool) in
            _processed += 1
            return (_processed, _cancelled)
        }
        onFrameEncoded(count)
        return !cancelled
    }

    func addError(_ message: String) {
        lock.withLock { _errors.append(message) }
    }

    var errors: [String] { lock.withLock { _errors } }
}

public struct GifskiOptions: Sendable {
    public var quality: Int = 90
    public var lossyQuality: Int?
    public var motionQuality: Int?
    public var fast = false
    public var repeatCount = 0

    public init() {}
}

/// Thin Swift wrapper around libgifski's C API.
///
/// Frames must be added in order from a single thread; `finish()` blocks until the file is written.
public final class GifskiEncoder: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let context: EncoderContext
    private let contextPointer: UnsafeMutableRawPointer
    private var frameIndex: UInt32 = 0
    private var finished = false

    public init(outputURL: URL, width: Int, height: Int, options: GifskiOptions,
                onFrameEncoded: @escaping @Sendable (Int) -> Void = { _ in }) throws {
        var settings = GifskiSettings(
            width: UInt32(width),
            height: UInt32(height),
            quality: UInt8(min(100, max(1, options.quality))),
            fast: options.fast,
            repeat: Int16(clamping: options.repeatCount)
        )
        guard let handle = gifski_new(&settings) else {
            throw GifTrimError.encodeFailed("无效的编码参数")
        }
        self.handle = handle
        context = EncoderContext(onFrameEncoded: onFrameEncoded)
        contextPointer = Unmanaged.passRetained(context).toOpaque()

        if let mq = options.motionQuality {
            _ = gifski_set_motion_quality(handle, UInt8(min(100, max(1, mq))))
        }
        if let lq = options.lossyQuality {
            _ = gifski_set_lossy_quality(handle, UInt8(min(100, max(1, lq))))
        }
        _ = gifski_set_progress_callback(handle, { userData in
            guard let userData else { return 1 }
            let ctx = Unmanaged<EncoderContext>.fromOpaque(userData).takeUnretainedValue()
            return ctx.frameProcessed() ? 1 : 0
        }, contextPointer)
        _ = gifski_set_error_message_callback(handle, { message, userData in
            guard let message, let userData else { return }
            let ctx = Unmanaged<EncoderContext>.fromOpaque(userData).takeUnretainedValue()
            ctx.addError(String(cString: message))
        }, contextPointer)

        let status = outputURL.withUnsafeFileSystemRepresentation { path in
            gifski_set_file_output(handle, path)
        }
        guard status == GIFSKI_OK else {
            _ = gifski_finish(handle)
            self.handle = nil
            throw GifTrimError.encodeFailed(Self.describe(status))
        }
    }

    deinit {
        if let handle, !finished {
            context.cancelled = true
            _ = gifski_finish(handle)
        }
        Unmanaged<EncoderContext>.fromOpaque(contextPointer).release()
    }

    public func cancel() {
        context.cancelled = true
    }

    public var isCancelled: Bool { context.cancelled }

    /// Adds a frame. `pixels` must be RGBA (non-premultiplied), sRGB, `bytesPerRow` stride.
    /// `pts` is the presentation timestamp in seconds. May block while the encoder catches up.
    public func addFrame(rgba pixels: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int, pts: Double) throws {
        guard let handle, !finished else { throw GifTrimError.encodeFailed("编码器已结束") }
        if context.cancelled { throw GifTrimError.cancelled }
        let status = gifski_add_frame_rgba_stride(
            handle, frameIndex, UInt32(width), UInt32(height), UInt32(bytesPerRow),
            pixels.assumingMemoryBound(to: UInt8.self), pts
        )
        frameIndex += 1
        if status == GIFSKI_ABORTED || context.cancelled { throw GifTrimError.cancelled }
        guard status == GIFSKI_OK else { throw GifTrimError.encodeFailed(Self.describe(status)) }
    }

    /// Finishes writing. Blocks until done.
    public func finish() throws {
        guard let handle, !finished else { return }
        finished = true
        self.handle = nil
        let status = gifski_finish(handle)
        if context.cancelled || status == GIFSKI_ABORTED { throw GifTrimError.cancelled }
        guard status == GIFSKI_OK else {
            let detail = context.errors.last.map { "\(Self.describe(status))（\($0)）" } ?? Self.describe(status)
            throw GifTrimError.encodeFailed(detail)
        }
    }

    static func describe(_ status: GifskiError) -> String {
        switch status {
        case GIFSKI_OK: return "成功"
        case GIFSKI_NULL_ARG: return "参数为空"
        case GIFSKI_INVALID_STATE: return "调用顺序错误"
        case GIFSKI_QUANT: return "调色板量化失败"
        case GIFSKI_GIF: return "GIF 合成失败"
        case GIFSKI_THREAD_LOST: return "编码线程意外退出"
        case GIFSKI_NOT_FOUND: return "找不到文件或目录"
        case GIFSKI_PERMISSION_DENIED: return "没有写入权限"
        case GIFSKI_ALREADY_EXISTS: return "文件已存在"
        case GIFSKI_INVALID_INPUT: return "输入无效"
        case GIFSKI_ABORTED: return "已取消"
        default: return "I/O 或未知错误 (\(status.rawValue))"
        }
    }
}
