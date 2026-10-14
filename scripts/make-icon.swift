// Generates the GifTrim app icon as an .iconset (run: swift scripts/make-icon.swift <out.iconset>).
import AppKit
import CoreGraphics

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: 824/1024 rounded rect, centered.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.025,
                  color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 1.0, green: 0.42, blue: 0.29, alpha: 1),
        CGColor(srgbRed: 0.93, green: 0.22, blue: 0.55, alpha: 1),
        CGColor(srgbRed: 0.45, green: 0.25, blue: 0.95, alpha: 1),
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.maxX, y: body.minY), options: [])

    // Film strip frames.
    let frameW = body.width * 0.62
    let frameH = body.height * 0.42
    let fx = body.midX - frameW / 2
    let fy = body.midY - frameH / 2 + body.height * 0.06
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.18))
    ctx.addPath(CGPath(roundedRect: CGRect(x: fx + s * 0.05, y: fy - s * 0.05, width: frameW, height: frameH),
                       cornerWidth: s * 0.04, cornerHeight: s * 0.04, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.95))
    let front = CGRect(x: fx - s * 0.02, y: fy + s * 0.02, width: frameW, height: frameH)
    ctx.addPath(CGPath(roundedRect: front, cornerWidth: s * 0.04, cornerHeight: s * 0.04, transform: nil))
    ctx.fillPath()

    // Play triangle.
    ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.22, blue: 0.55, alpha: 1))
    let tri = CGMutablePath()
    let c = CGPoint(x: front.midX + s * 0.01, y: front.midY)
    let r = frameH * 0.26
    tri.move(to: CGPoint(x: c.x - r * 0.75, y: c.y + r))
    tri.addLine(to: CGPoint(x: c.x + r, y: c.y))
    tri.addLine(to: CGPoint(x: c.x - r * 0.75, y: c.y - r))
    tri.closeSubpath()
    ctx.addPath(tri)
    ctx.fillPath()

    // Trim bar.
    let barY = body.minY + body.height * 0.17
    let bar = CGRect(x: body.minX + body.width * 0.16, y: barY, width: body.width * 0.68, height: body.height * 0.09)
    ctx.setFillColor(CGColor(gray: 0, alpha: 0.25))
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: bar.height / 2, cornerHeight: bar.height / 2, transform: nil))
    ctx.fillPath()
    let sel = bar.insetBy(dx: bar.width * 0.18, dy: 0)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.84, blue: 0.2, alpha: 1))
    ctx.setLineWidth(max(1, s * 0.018))
    ctx.addPath(CGPath(roundedRect: sel, cornerWidth: bar.height / 3, cornerHeight: bar.height / 3, transform: nil))
    ctx.strokePath()
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
print("wrote \(out)")
