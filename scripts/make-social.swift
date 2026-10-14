// Renders a 1280x640 GitHub social preview card.
// Usage: swift scripts/make-social.swift <screenshot.png> <icon.png> <out.png>
import AppKit

let args = CommandLine.arguments
let shot = NSImage(contentsOfFile: args[1])!
let icon = NSImage(contentsOfFile: args[2])!
let size = NSSize(width: 1280, height: 640)

let image = NSImage(size: size, flipped: true) { rect in
    NSGradient(colors: [NSColor(srgbRed: 0.09, green: 0.06, blue: 0.16, alpha: 1),
                        NSColor(srgbRed: 0.24, green: 0.07, blue: 0.27, alpha: 1)])!
        .draw(in: rect, angle: 20)

    icon.draw(in: NSRect(x: 64, y: 70, width: 104, height: 104))

    func draw(_ s: String, font: NSFont, color: NSColor, at p: NSPoint, width: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        (s as NSString).draw(with: NSRect(x: p.x, y: p.y, width: width, height: 300),
                             options: [.usesLineFragmentOrigin],
                             attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }
    draw("GifTrim", font: .systemFont(ofSize: 72, weight: .heavy), color: .white,
         at: NSPoint(x: 64, y: 196), width: 560)
    draw("Beautiful, tiny GIFs on your Mac —\nor let your AI make them.",
         font: .systemFont(ofSize: 30, weight: .semibold), color: NSColor(white: 1, alpha: 0.92),
         at: NSPoint(x: 64, y: 296), width: 560)
    draw("Video → GIF · Screen & iPhone recording · Captions\ngifski quality · CLI · MCP server · Free & open source",
         font: .systemFont(ofSize: 20, weight: .medium), color: NSColor(srgbRed: 1, green: 0.75, blue: 0.88, alpha: 1),
         at: NSPoint(x: 64, y: 420), width: 580)
    draw("github.com/swsususu/GifTrim", font: .monospacedSystemFont(ofSize: 18, weight: .medium),
         color: NSColor(white: 1, alpha: 0.6), at: NSPoint(x: 64, y: 560), width: 560)

    // Screenshot, tilted card style.
    let w: CGFloat = 600
    let h = w * shot.size.height / shot.size.width
    let frame = NSRect(x: 650, y: (640 - h) / 2, width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 40
    shadow.shadowOffset = NSSize(width: 0, height: 12)
    shadow.shadowColor = NSColor(white: 0, alpha: 0.55)
    shadow.set()
    NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14).addClip()
    shot.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 640, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(origin: .zero, size: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
print("wrote \(args[3])")
