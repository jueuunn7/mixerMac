import SwiftUI

/// Printed channel divisions on a shared, flat silver console surface.
struct ConsoleChannelPlate: View {
    var channelNumber: Int? = nil
    var master = false
    var fillsSurface = true

    var body: some View {
        Canvas { context, size in
            let surface = CGRect(origin: .zero, size: size)
            if fillsSurface { context.fill(Path(surface), with: .color(Color(white: 0.76))) }

            let scaleX = size.width / ConsoleLayout.stripWidth
            let ink = Color(white: 0.16)

            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scaleX, y: y)
            }

            let printing = Path { path in
                path.move(to: point(0, 0))
                path.addLine(to: point(0, size.height))
            }
            context.stroke(
                printing,
                with: .color(ink),
                style: StrokeStyle(lineWidth: 1.35, lineCap: .butt, lineJoin: .miter)
            )

            guard let channelNumber else { return }

            // Keep the header's first control at least 24 points from the
            // strip's leading edge to leave this printed badge unobscured.
            let badge = CGRect(
                x: 0, y: 7,
                width: 18 * scaleX, height: 18
            )
            // The hardware badge has square left corners and rounded right
            // corners, and shares its left edge with the channel rail.
            let badgePath = Path { path in
                path.move(to: CGPoint(x: badge.minX, y: badge.maxY))
                path.addLine(to: CGPoint(x: badge.minX, y: badge.minY))
                path.addLine(to: CGPoint(x: badge.maxX - 4 * scaleX, y: badge.minY))
                path.addQuadCurve(to: CGPoint(x: badge.maxX, y: badge.minY + 4),
                                  control: CGPoint(x: badge.maxX, y: badge.minY))
                path.addLine(to: CGPoint(x: badge.maxX, y: badge.maxY - 4))
                path.addQuadCurve(to: CGPoint(x: badge.maxX - 4 * scaleX, y: badge.maxY),
                                  control: CGPoint(x: badge.maxX, y: badge.maxY))
                path.closeSubpath()
            }
            context.stroke(badgePath, with: .color(ink), lineWidth: 1.15)
            context.draw(
                Text(String(channelNumber))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(ink),
                at: CGPoint(x: badge.midX, y: badge.midY)
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
