import MixerCore
import MixerStandardNodes
import SwiftUI

struct ConsoleWidthControl: View {
    @Binding var value: Float
    var body: some View {
        ConsoleStereoDial(value: Binding(get: { (value - 1) * 24 }, set: { value = StereoWidth.quantized($0 / 24 + 1) }),
            title: "WIDTH", readout: StereoWidth.label(value))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Master stereo width")
        .accessibilityValue(StereoWidth.label(value))
        .accessibilityAdjustableAction { direction in
            value = StereoWidth.quantized(value + (direction == .increment ? 0.05 : -0.05))
        }
        .accessibilityAction(named: Text("Reset to 100 percent")) { value = 1 }
        .help("WIDTH \(StereoWidth.label(value)) · 0% mono / 100% original / 200% wide · double-click resets")
    }
}

struct DetailWidthControl: View {
    @Binding var value: Float
    var body: some View {
        HStack(spacing: 5) {
            Text("WIDTH").font(.system(size: 10, weight: .bold))
            Slider(value: Binding(get: { Double(value) }, set: { value = StereoWidth.quantized(Float($0)) }), in: 0...2)
                .frame(width: 75).controlSize(.mini)
                .accessibilityLabel("Master stereo width")
                .simultaneousGesture(TapGesture(count: 2).onEnded { value = 1 })
            Button { value = 1 } label: {
                Text(StereoWidth.label(value)).font(.system(size: 9, design: .monospaced)).frame(width: 36)
            }.buttonStyle(.plain).help("Reset WIDTH to 100% original stereo")
        }
    }
}
