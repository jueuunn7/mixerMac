#!/usr/bin/env swift
import AppKit
import ImageIO

// Native rendering of the console mark; all dimensions use a 160-point canvas.
let size = 1024
let space = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Cannot create icon canvas")
}
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: CGFloat(size) / 160, y: -CGFloat(size) / 160)
// Keep the artwork inside an approximately 824-pixel optical square.
context.translateBy(x: 80, y: 80)
context.scaleBy(x: 0.89, y: 0.89)
context.translateBy(x: -80, y: -80)
func gray(_ value: CGFloat) -> CGColor { CGColor(gray: value, alpha: 1) }
func gradient(_ path: CGPath, shades: [CGFloat], locations: [CGFloat], from: CGPoint, to: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let colors = shades.map { NSColor(white: $0, alpha: 1).cgColor } as CFArray
    if let fill = CGGradient(colorsSpace: space, colors: colors, locations: locations) {
        context.drawLinearGradient(fill, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    context.restoreGState()
}
func line(_ points: [CGPoint], shade: CGFloat, width: CGFloat) {
    guard let first = points.first else { return }
    context.beginPath(); context.move(to: first)
    for point in points.dropFirst() { context.addLine(to: point) }
    context.setStrokeColor(gray(shade)); context.setLineWidth(width); context.strokePath()
}
let panel = CGPath(roundedRect: CGRect(x: 8, y: 7, width: 144, height: 144),
                   cornerWidth: 32, cornerHeight: 32, transform: nil)
gradient(panel, shades: [0.89, 0.65], locations: [0, 1], from: CGPoint(x: 8, y: 7), to: CGPoint(x: 44, y: 151))
context.addPath(panel); context.setStrokeColor(gray(0.6)); context.setLineWidth(0.8); context.strokePath()
for x in [CGFloat(25), 135] {
    for y in [CGFloat(24), 142] {
        context.setFillColor(gray(0.14)); context.fillEllipse(in: CGRect(x: x-3, y: y-3, width: 6, height: 6))
        line([CGPoint(x: x-1.8, y: y+1.8), CGPoint(x: x+1.8, y: y-1.8)], shade: 0.47, width: 0.8)
    }
}
for x in [CGFloat(58), 102] { line([CGPoint(x: x, y: 29), CGPoint(x: x, y: 130)], shade: 0.42, width: 0.8) }
for (index, x) in [CGFloat(36), 80, 124].enumerated() {
    context.setFillColor(gray(0.08)); context.fillEllipse(in: CGRect(x: x-14.7, y: 39.8, width: 29.4, height: 29.4))
    let rim = CGMutablePath()
    for sample in 0..<180 {
        let angle = Double(sample) * .pi / 90
        let radius = 14 * (0.965 + 0.035 * cos(angle * 10))
        let point = CGPoint(x: x + cos(angle)*radius, y: 54 + sin(angle)*radius)
        if sample == 0 { rim.move(to: point) } else { rim.addLine(to: point) }
    }
    rim.closeSubpath()
    gradient(rim, shades: [0.29, 0.075, 0.19], locations: [0, 0.5, 1],
             from: CGPoint(x: x-14, y: 40), to: CGPoint(x: x+14, y: 68))
    context.addPath(rim); context.setStrokeColor(gray(0.03)); context.setLineWidth(0.7); context.strokePath()
    context.setFillColor(gray(0.07)); context.fillEllipse(in: CGRect(x: x-10.5, y: 43.5, width: 21, height: 21))
    context.setLineCap(.round)
    line([CGPoint(x: x, y: 43), CGPoint(x: x, y: 52)], shade: 0.97, width: 1.8)
    context.setLineCap(.butt)
    line([CGPoint(x: x, y: 84), CGPoint(x: x, y: 133)], shade: 0.08, width: 4)
    for y in stride(from: CGFloat(88), through: 133, by: 9) {
        line([CGPoint(x: x-13, y: y), CGPoint(x: x-8, y: y)], shade: 0.4, width: 0.8)
    }
    let capY: CGFloat = [93, 111, 87][index]
    let cap = CGPath(roundedRect: CGRect(x: x-12, y: capY, width: 24, height: 11),
                     cornerWidth: 2, cornerHeight: 2, transform: nil)
    gradient(cap, shades: [0.4, 0.14, 0.08, 0.87, 0.97, 0.13, 0.03],
             locations: [0, 0.35, 0.48, 0.5, 0.59, 0.64, 1],
             from: CGPoint(x: x, y: capY), to: CGPoint(x: x, y: capY+11))
    context.addPath(cap); context.setStrokeColor(gray(0.03)); context.setLineWidth(1); context.strokePath()
}
guard CommandLine.arguments.count == 2, let image = context.makeImage() else { fatalError("Usage: render_icon.swift output.png") }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let bitmap = NSBitmapImageRep(cgImage: image)
guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
try png.write(to: output)
