import SwiftUI

private typealias ConsoleKnobState<Value> = SwiftUI.State<Value>

/// A rubber grip with rounded, shallow scallops rather than gear teeth.
private struct ConsoleKnobRim: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            let radius = min(rect.width, rect.height) / 2
            for sample in 0..<180 {
                let angle = Double(sample) * .pi / 90
                let scallop = 0.965 + 0.035 * cos(angle * 10)
                let point = CGPoint(
                    x: rect.midX + cos(angle) * radius * scallop,
                    y: rect.midY + sin(angle) * radius * scallop
                )
                if sample == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
    }
}

private enum ConsoleKnobValue {
    static func quantized(_ raw: Float) -> Float {
        guard raw.isFinite else { return 0 }
        return min(24, max(-24, abs(raw) < 0.35 ? 0 : (raw * 2).rounded() / 2))
    }

    static func adjust(_ value: Float, direction: AccessibilityAdjustmentDirection) -> Float {
        switch direction {
        case .increment: return quantized(value + 0.5)
        case .decrement: return quantized(value - 0.5)
        @unknown default: return value
        }
    }
}

struct ConsoleEQKnob: View {
    @Binding var value: Float
    var trim: Bool = false
    var tickRadius: CGFloat = 20
    @ConsoleKnobState private var initial: Float?

    private let ink = Color(white: 0.12)

    var body: some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = max(17, tickRadius)
                func point(_ angle: Double, _ distance: CGFloat) -> CGPoint {
                    let radians = angle * .pi / 180
                    return CGPoint(x: center.x + sin(radians) * distance,
                                   y: center.y - cos(radians) * distance)
                }
                var marks = Path()
                do {
                    // Fine graduations sit on the lower cheeks of the knob.
                    for angle in stride(from: -120, through: 120, by: 10)
                    where abs(angle) >= 40 && abs(angle) != 90 {
                        marks.move(to: point(Double(angle), radius - 2.5))
                        marks.addLine(to: point(Double(angle), radius + 0.5))
                    }
                }
                context.stroke(marks, with: .color(ink.opacity(0.85)), lineWidth: 0.65)

                var major = Path()
                for side in [-1.0, 1.0] {
                    major.move(to: point(side * 90, radius - 3))
                    major.addLine(to: point(side * 90, radius + 5))
                    // Each endpoint branches diagonally, then turns outward.
                    major.move(to: point(side * 135, radius - 2))
                    major.addLine(to: CGPoint(x: center.x + CGFloat(side) * (radius - 1),
                                             y: center.y + radius - 1))
                    major.addLine(to: CGPoint(x: center.x + CGFloat(side) * (radius + 5),
                                             y: center.y + radius - 1))
                }
                context.stroke(major, with: .color(ink),
                               style: StrokeStyle(lineWidth: 1.05, lineCap: .butt, lineJoin: .miter))

                // The printed zero marker narrows toward the rubber cap.
                let top = center.y - 14 - 3.8
                var zero = Path()
                zero.move(to: CGPoint(x: center.x, y: top + 4))
                zero.addCurve(to: CGPoint(x: center.x - 1.7, y: top + 1),
                              control1: CGPoint(x: center.x - 0.7, y: top + 2.8),
                              control2: CGPoint(x: center.x - 1.7, y: top + 2.2))
                zero.addCurve(to: CGPoint(x: center.x + 1.7, y: top + 1),
                              control1: CGPoint(x: center.x - 1.7, y: top - 1),
                              control2: CGPoint(x: center.x + 1.7, y: top - 1))
                zero.addQuadCurve(to: CGPoint(x: center.x, y: top + 4),
                                  control: CGPoint(x: center.x + 1.7, y: top + 2.4))
                context.fill(zero, with: .color(ink))
            }
            // Canvas clips to its own drawing bounds. Give the printing room
            // while reporting only the physical cap's size to the stack.
            .frame(width: 56, height: 56)
            .frame(width: 28, height: 28)
            .allowsHitTesting(false)

            ZStack {
                Circle().fill(.black.opacity(0.75)).padding(-0.7)
                    .shadow(color: .black.opacity(0.35), radius: 1.1, x: 0.6, y: 1.3)
                ConsoleKnobRim()
                    .fill(LinearGradient(colors: [Color(white: 0.29), Color(white: 0.075), Color(white: 0.19)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(ConsoleKnobRim().stroke(.black.opacity(0.85), lineWidth: 0.7))
                    .rotationEffect(.degrees(Double(min(24, max(-24, value))) * 5.625))
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.12), Color(white: 0.055)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Circle().stroke(.white.opacity(0.06), lineWidth: 0.6))
                    .padding(3)
                Capsule().fill(Color(white: 0.97))
                    .frame(width: 1.8, height: 11).offset(y: -6.2)
                    .rotationEffect(.degrees(Double(min(24, max(-24, value))) * 5.625))
            }
            .frame(width: 28, height: 28)
        }
        .frame(width: 28, height: 28)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { event in
                if initial == nil { initial = value }
                value = ConsoleKnobValue.quantized((initial ?? value) - Float(event.translation.height) * 0.14)
            }
            .onEnded { _ in initial = nil })
        .simultaneousGesture(TapGesture(count: 2).onEnded { initial = nil; value = 0 })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(trim ? "Gain" : "EQ gain")
        .accessibilityValue(String(format: "%+.1f dB", value))
        .accessibilityAdjustableAction { value = ConsoleKnobValue.adjust(value, direction: $0) }
        .accessibilityAction(named: Text("Reset to 0 dB")) { value = 0 }
        .help("Drag up or down · double-click resets to 0 dB")
    }
}

struct ConsolePrintedKnob: View {
    @Binding var value: Float
    let label: String
    var trim: Bool = false

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2,
                                 y: geometry.size.height / 2 - 2.5)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    let ink = Color(white: 0.12)
                    let title = Text(label).font(.system(size: 8, weight: .bold))
                        .foregroundStyle(ink)
                    context.draw(title,
                                 at: CGPoint(x: 12, y: center.y - 7.5),
                                 anchor: .leading)
                    let low = Text("−24").font(.system(size: 7, weight: .medium)).foregroundStyle(ink)
                    let high = Text("+24").font(.system(size: 7, weight: .medium)).foregroundStyle(ink)
                    // Anchor the text inside the row, clear of both endpoint lines.
                    context.draw(low, at: CGPoint(x: center.x - 27, y: center.y + 17), anchor: .trailing)
                    context.draw(high, at: CGPoint(x: center.x + 27, y: center.y + 17), anchor: .leading)
                }.allowsHitTesting(false)
                ConsoleEQKnob(value: $value, trim: trim, tickRadius: 18)
                    .position(center)
            }
        }
        .frame(height: ConsoleLayout.eqRowHeight)
        .foregroundStyle(Color(white: 0.12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.replacingOccurrences(of: "\n", with: " ") + " gain")
        .accessibilityValue(String(format: "%+.1f dB", value))
        .accessibilityAdjustableAction { value = ConsoleKnobValue.adjust(value, direction: $0) }
        .accessibilityAction(named: Text("Reset to 0 dB")) { value = 0 }
        .help(String(format: "%+.1f dB · drag to adjust · double-click resets", value))
    }
}
