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

            // One leading rail per strip: its neighbour supplies the next
            // divider on the shared console surface. Do not outline
            // both sides of each channel and create paired parallel borders.
            let scaleX = size.width / ConsoleLayout.stripWidth
            let ink = Color(white: 0.16)

            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scaleX, y: y)
            }

            func rail(_ vertices: [CGPoint]) -> Path {
                Path { path in
                    guard let first = vertices.first else { return }
                    path.move(to: first)
                    for vertex in vertices.dropFirst() {
                        path.addLine(to: vertex)
                    }
                }
            }

            let segments: [[CGPoint]] = [
                [point(0, master ? ConsoleLayout.stripTopInset : 25),
                 point(0, master ? 105 : 103)],
                [point(0, master ? ConsoleLayout.masterEQTop : ConsoleLayout.appEQTop),
                 point(0, (master ? ConsoleLayout.masterEQTop : ConsoleLayout.appEQTop) + ConsoleLayout.eqBankHeight)],
                [point(0, master ? ConsoleLayout.masterControlsTop : ConsoleLayout.appControlsTop),
                 point(0, master ? ConsoleLayout.masterControlsBottom : ConsoleLayout.appControlsTop + ConsoleLayout.channelControlsHeight)],
                [point(0, master ? ConsoleLayout.masterMeterTop : ConsoleLayout.appFaderTop),
                 point(0, master ? ConsoleLayout.masterMeterBottom : ConsoleLayout.appFaderTop + ConsoleLayout.appFaderHeight)]
            ]

            var printing = Path()
            for segment in segments {
                printing.addPath(rail(segment))
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
