import MixerCore
import MixerStandardNodes
import SwiftUI

private typealias FaderState<Value> = SwiftUI.State<Value>

/// One setting path for graph dragging, numeric entry, and the graphic faders.
func setDetailGain(_ gain: Float, band: Int, settings: Binding<ChannelSettings>) {
    guard gain.isFinite else { return }
    settings.wrappedValue.gains[band] = min(24, max(-24, (gain * 10).rounded() / 10))
}

/// A graph drag edits both coordinates with one model/persistence notification.
func setDetailBand(_ band: Int, frequency: Float, gain: Float, settings: Binding<ChannelSettings>) {
    guard frequency.isFinite, gain.isFinite else { return }
    var updated = settings.wrappedValue
    updated.frequencies[band] = min(20_000, max(20, frequency))
    updated.gains[band] = min(24, max(-24, (gain * 10).rounded() / 10))
    settings.wrappedValue = updated
}

struct DetailFaderBank: View {
    @Binding var settings: ChannelSettings
    @Binding var selectedBand: Int
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<10) { band in
                VStack(spacing: 6) {
                    Button(String(format: "%02d", band + 1)) { selectedBand = band }
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(selectedBand == band ? Color.blue : Color.secondary)
                        .buttonStyle(.plain)
                    Text(frequency(settings.frequencies[band]))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    DetailEQFader(value: Binding(get: { settings.gains[band] }, set: {
                        setDetailGain($0, band: band, settings: $settings)
                    }), select: { selectedBand = band })
                        .frame(height: 186)
                        .accessibilityLabel("Band \(band + 1) EQ fader")
                    DetailNumberField(value: Binding(get: { Double(settings.gains[band]) }, set: {
                        setDetailGain(Float($0), band: band, settings: $settings)
                    }), label: "Band \(band + 1) gain", digits: 1).frame(width: 59)
                }
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(selectedBand == band ? Color.white.opacity(0.28) : Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(8)
        .background(.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 5))
    }

    private func frequency(_ value: Float) -> String {
        if value >= 1000 { return String(format: value.truncatingRemainder(dividingBy: 1000) == 0 ? "%.0fk" : "%.1fk", value / 1000) }
        return String(format: value.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", value)
    }
}

private struct DetailEQFader: View {
    @Binding var value: Float
    let select: () -> Void
    @FaderState private var initial: Float?

    var body: some View {
        GeometryReader { proxy in
            let travel = max(1, proxy.size.height - 30)
            ZStack {
                ForEach([-24, -12, 0, 12, 24], id: \.self) { gain in
                    let y = travel * (0.5 - CGFloat(EQFaderScale.position(for: Float(gain))))
                    Rectangle().fill(.black.opacity(gain == 0 ? 0.7 : 0.3))
                        .frame(width: 8, height: gain == 0 ? 1.2 : 0.7).offset(x: -10, y: y)
                    Text(gain > 0 ? "+\(gain)" : "\(gain)")
                        .font(.system(size: 6.5, weight: gain == 0 ? .bold : .medium, design: .monospaced))
                        .foregroundStyle(.black.opacity(0.6)).offset(x: -24, y: y)
                }
                RoundedRectangle(cornerRadius: 2).fill(.black.opacity(0.88))
                    .frame(width: 5, height: travel + 12)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(.white.opacity(0.4), lineWidth: 0.5))
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [Color(white: 0.3), Color(white: 0.04), Color(white: 0.17)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 28, height: 15)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(.black, lineWidth: 0.7))
                    .overlay(Rectangle().fill(.white.opacity(0.95)).frame(height: 1.5))
                    .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0.6, y: 1.5)
                    .offset(y: travel * (0.5 - CGFloat(EQFaderScale.position(for: value))))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                if initial == nil { initial = EQFaderScale.position(for: value); select() }
                value = EQFaderScale.gain(at: (initial ?? 0.5) - Float(event.translation.height / travel))
            }.onEnded { _ in initial = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { select(); value = 0 })
            .accessibilityElement(children: .ignore)
            .accessibilityValue(String(format: "%+.1f dB", value))
            .accessibilityAdjustableAction { direction in
                select()
                let step: Float = direction == .increment ? 0.1 : -0.1
                value = min(24, max(-24, (value * 10 + step * 10).rounded() / 10))
            }
            .accessibilityAction(named: Text("Reset to 0 dB")) { value = 0 }
            .help("EQ gain · −24 to +24 dB · center = 0 dB · double-click resets")
        }
    }
}
