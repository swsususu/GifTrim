import AVFoundation
import CoreGraphics
import CoreText
import Foundation

/// Generates synthetic test videos (moving shapes, gradients, frame counter).
public enum TestVideoGenerator {
    public static func make(url: URL, width: Int = 640, height: Int = 360, fps: Int = 30, seconds: Double = 3) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? GifTrimError.encodeFailed("writer") }
        writer.startSession(atSourceTime: .zero)

        let total = Int(seconds * Double(fps))
        for i in 0..<total {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? GifTrimError.encodeFailed("writer") }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw GifTrimError.encodeFailed("pool") }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pixelBuffer = pb else { throw GifTrimError.encodeFailed("pixel buffer") }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            draw(frame: i, total: total, in: ctx, width: Double(width), height: Double(height))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))) else {
                throw writer.error ?? GifTrimError.encodeFailed("append")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? GifTrimError.encodeFailed("writer") }
    }

    static func draw(frame i: Int, total: Int, in ctx: CGContext, width w: Double, height h: Double) {
        let p = Double(i) / Double(max(1, total))
        let colors = [
            CGColor(srgbRed: 0.1 + 0.4 * p, green: 0.2, blue: 0.5, alpha: 1),
            CGColor(srgbRed: 0.9, green: 0.5 + 0.3 * p, blue: 0.2, alpha: 1),
        ] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        // Moving ball
        let r = h * 0.12
        let x = r + (w - 2 * r) * p
        let y = h / 2 + sin(p * .pi * 4) * h * 0.3
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        // Top-left marker (to verify orientation): red square at top-left.
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h - h * 0.15, width: h * 0.15, height: h * 0.15))
        // Frame counter
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, h * 0.1, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "#\(i)", attributes: attrs))
        ctx.textPosition = CGPoint(x: w * 0.7, y: h * 0.05)
        CTLineDraw(line, ctx)
    }
}
