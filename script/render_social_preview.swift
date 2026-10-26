#!/usr/bin/env swift
import AppKit

// Keep the full wordmark visible in a 1.91:1 social-link card.
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 630,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: 1200, height: 630).fill()
guard let logo = NSImage(contentsOfFile: "docs/assets/logo.png") else { fatalError("Missing logo.png") }
logo.draw(in: NSRect(x: 0, y: 155, width: 1200, height: 320))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/assets/social-preview.png"))
