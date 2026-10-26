import SwiftUI

enum PanBalance {
    static func clamped(_ value: Float) -> Float {
        value.isFinite ? min(1, max(-1, value)) : 0
    }
    static func label(_ value: Float) -> String {
        let percentage = Int((abs(clamped(value)) * 100).rounded())
        return percentage == 0 ? "C" : "\(value < 0 ? "L" : "R") \(percentage)"
    }
    static func quantized(_ value: Float) -> Float { (clamped(value) * 100).rounded() / 100 }
}

struct ConsolePanControl: View {
    @Binding var value: Float
    var compact = false
    var body: some View {
        Group {
            if compact {
                ConsoleStereoDial(value: Binding(get: { value * 24 }, set: { value = PanBalance.quantized($0 / 24) }),
                    title: "PAN", readout: PanBalance.label(value))
            } else {
        VStack(spacing: 4) {
            Text("PAN").font(.system(size: 7, weight: .bold))
            dial
            Text(PanBalance.label(value)).font(.system(size: 6, weight: .medium, design: .monospaced)).frame(height: 7)
        }
        .frame(width: 42, height: 52)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pan")
        .accessibilityValue(PanBalance.label(value))
        .accessibilityAdjustableAction { direction in
            value = PanBalance.quantized(value + (direction == .increment ? 0.05 : -0.05))
        }
        .accessibilityAction(named: Text("Reset to center")) { value = 0 }
        .help("PAN \(PanBalance.label(value)) · L / C / R · center preserves stereo · double-click resets")
    }

    private var dial: some View {
        ConsoleEQKnob(value: Binding(get: { value * 24 }, set: { value = PanBalance.quantized($0 / 24) }), trim: true, tickRadius: 18)
            .frame(width: 28, height: 28)
    }
}

/// Identical cap size, baseline, and captions for the two master controls.
struct ConsoleStereoDial: View {
    @Binding var value: Float
    let title: String
    let readout: String
    var body: some View {
        VStack(spacing: 4) {
            ConsoleEQKnob(value: $value, trim: true, tickRadius: 18)
                .frame(width: 28, height: 28)
            HStack(spacing: 3) {
                Text(title).font(.system(size: 7, weight: .bold))
                Text(readout).font(.system(size: 7, design: .monospaced))
            }.fixedSize()
        }.frame(width: 46, height: 44)
    }
}

struct DetailPanControl: View {
    @Binding var value: Float
    var body: some View {
        HStack(spacing: 5) {
            Text("PAN").font(.system(size: 10, weight: .bold))
            Slider(value: Binding(get: { Double(value) }, set: { value = PanBalance.quantized(Float($0)) }), in: -1...1)
                .frame(width: 75).controlSize(.mini)
                .accessibilityLabel("Channel pan")
                .simultaneousGesture(TapGesture(count: 2).onEnded { value = 0 })
            Button { value = 0 } label: {
                Text(PanBalance.label(value)).font(.system(size: 9, design: .monospaced)).frame(width: 32)
            }.buttonStyle(.plain).help("Reset PAN to center")
        }
    }
}
