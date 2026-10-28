import MixerCore
import MixerStandardNodes
import SwiftUI

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

/// One shared two-column grid for channel and master stereo controls.
struct ConsoleStereoPair: View {
    @Binding var pan: Float
    @Binding var width: Float
    let accessibilityPrefix: String

    var body: some View {
        HStack(spacing: 0) {
            ConsolePanControl(value: $pan, compact: true)
                .accessibilityLabel("\(accessibilityPrefix) pan")
            ConsoleWidthControl(value: $width)
                .accessibilityLabel("\(accessibilityPrefix) stereo width")
        }
        .frame(width: ConsoleLayout.controlBankWidth, height: ConsoleLayout.masterStereoRowHeight)
    }
}

/// Explicit centres keep the cap and its caption independent of text width.
struct ConsoleStereoDial: View {
    @Binding var value: Float
    let title: String
    let readout: String
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ConsoleEQKnob(value: $value, trim: true, tickRadius: 18)
                    .position(x: geometry.size.width / 2, y: 24)
                Text(title).font(.system(size: 8, weight: .bold))
                    .fixedSize()
                    .frame(width: geometry.size.width - 6, alignment: .leading)
                    .position(x: geometry.size.width / 2, y: 0)
                    .allowsHitTesting(false)
                Text(readout).font(.system(size: 7, design: .monospaced))
                    .fixedSize()
                    .position(x: geometry.size.width / 2, y: 48)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: ConsoleLayout.controlBankWidth / 2, height: ConsoleLayout.masterStereoRowHeight)
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
