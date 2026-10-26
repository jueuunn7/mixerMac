import AppKit
import ImageIO
let size = NSSize(width: 1200, height: 320)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 320,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 32, yRadius: 32).fill()
let icon = NSImage(contentsOfFile: "Resources/AppIcon.png")!
icon.draw(in: NSRect(x: 10, y: 0, width: 320, height: 320))
let label = "mixerMac" as NSString
label.draw(at: NSPoint(x: 350, y: 92), withAttributes: [
    .font: NSFont.systemFont(ofSize: 126, weight: .bold),
    .foregroundColor: NSColor(white: 0.15, alpha: 1),
    .kern: -5
])
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/assets/logo.png"))
