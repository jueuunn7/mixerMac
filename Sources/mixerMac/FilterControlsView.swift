import MixerAudio
import MixerCore
import MixerStandardNodes
import SwiftUI

struct ConsoleFilterStrip: View {
    @ObservedObject var mixer: MixerConsoleModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ConsoleScrew()
                Text("FILTERS").font(.system(size: 11, weight: .bold)).tracking(0.5)
                Spacer(minLength: 0)
            }.frame(height: ConsoleLayout.headerHeight)
            if let filters = mixer.filters {
                ForEach(Array(filters.banks.enumerated()), id: \.element.id) { index, bank in
                    ConsoleFilterBankControls(bank: bank, number: index + 1)
                        .frame(maxHeight: .infinity)
                    if index == 0 { Rectangle().fill(ConsolePalette.ink.opacity(0.6)).frame(height: 1).padding(.horizontal, 6) }
                }
            } else {
                Text("FILTERS UNAVAILABLE").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ConsolePalette.secondary).padding(.top, 20)
                Spacer()
            }
        }
        .padding(.horizontal, 12).padding(.top, ConsoleLayout.stripTopInset).padding(.bottom, ConsoleLayout.stripBottomInset)
        .frame(width: ConsoleLayout.stripWidth, height: ConsoleLayout.stripHeight)
        .background {
            Color(white: 0.76)
            HStack {
                Rectangle().fill(ConsolePalette.ink).frame(width: 1)
                Spacer()
            }.padding(.vertical, 7)
        }
        .foregroundStyle(ConsolePalette.ink)
    }
}

private struct ConsoleFilterBankControls: View {
    let bank: ConsoleFilterBank
    let number: Int
    @State private var bypassed = true
    @State private var selectedMode = 0

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 4) {
                Text("FILTER \(number)").font(.system(size: 9, weight: .bold)).tracking(0.6)
                Spacer()
                ConsoleButton(title: "ON", active: !bypassed, color: ConsolePalette.blue) {
                    let next = !bypassed
                    bypassed = next
                    bank.setBypassed(next)
                }
                    .frame(width: 44).accessibilityLabel("Filter \(number) enabled")
            }
            HStack(spacing: 3) {
                ForEach(Array(["LPF", "BPF", "HPF"].enumerated()), id: \.offset) { index, title in
                    ConsoleButton(title: title, active: selectedMode == index, color: ConsolePalette.blue, stacked: true) {
                        selectedMode = index
                        bank.filter.mode.setValue(Float(index))
                    }.accessibilityLabel("Filter \(number) \(title)")
                }
            }
            ConsoleFilterKnob(parameter: bank.filter.frequency, title: "FREQUENCY", accessibilityName: "Filter \(number) frequency", logarithmic: true, suffix: "Hz", large: true)
            HStack(spacing: 4) {
                ConsoleFilterKnob(parameter: bank.filter.resonance, title: "RES", accessibilityName: "Filter \(number) resonance", scale: 100, suffix: "%")
                ConsoleFilterKnob(parameter: bank.crunch.amount, title: "CRUNCH", accessibilityName: "Filter \(number) crunch", scale: 100, suffix: "%")
            }
        }
        .onAppear(perform: syncFromModel)
        .onReceive(bank.changes) { _ in syncFromModel() }
    }

    private func syncFromModel() {
        bypassed = bank.isBypassed
        selectedMode = Int(bank.filter.mode.value)
    }
}

private struct ConsoleFilterKnob: View {
    let parameter: Parameter
    let title: String
    let accessibilityName: String
    var logarithmic = false
    var scale: Double = 1
    let suffix: String
    var large = false
    @State private var value: Float = 0

    private var lower: Double { logarithmic ? log2(Double(parameter.range.lowerBound)) : Double(parameter.range.lowerBound) }
    private var upper: Double { logarithmic ? log2(Double(parameter.range.upperBound)) : Double(parameter.range.upperBound) }
    // Put the musical default (1 kHz) at the physical centre of a frequency
    // knob instead of using the geometric midpoint of 20 Hz...20 kHz (~632 Hz).
    private var centre: Double { logarithmic ? log2(1000) : (lower + upper) / 2 }
    private var position: Binding<Float> {
        Binding(get: {
            let current = logarithmic ? log2(Double(max(parameter.range.lowerBound, value))) : Double(value)
            let offset = current <= centre
                ? (current - centre) / (centre - lower) * 24
                : (current - centre) / (upper - centre) * 24
            return Float(offset)
        }, set: {
            let offset = Double($0)
            let current = offset <= 0
                ? centre + offset / 24 * (centre - lower)
                : centre + offset / 24 * (upper - centre)
            parameter.setValue(Float(logarithmic ? pow(2, current) : current))
        })
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(large ? title : title + " %").font(.system(size: 8, weight: .bold)).tracking(0.6)
                .lineLimit(1).minimumScaleFactor(0.8)
            ConsoleEQKnob(value: position, reset: { parameter.reset() })
                .scaleEffect(large ? 1.55 : 1)
                .frame(width: large ? 90 : 52, height: large ? 78 : 52)
                .accessibilityHidden(true)
            HStack(spacing: 2) {
                DetailNumberField(value: Binding(get: { Double(value) * scale },
                    set: { if $0.isFinite { parameter.setValue(Float($0 / scale)) } }), label: accessibilityName, digits: large ? 0 : 1)
                    .frame(width: large ? 62 : 52)
                if large { Text(suffix).font(.system(size: 8)).foregroundStyle(ConsolePalette.secondary) }
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { value = parameter.value }
        .onReceive(parameter.changes) { value = parameter.value }
        .help("\(accessibilityName) · drag vertically · double-click knob to reset")
    }
}

struct FilterAssignmentControl: View {
    let router: FilterRouterNode
    @State private var selection = 0
    @State private var dragOrigin: Int?
    private let positions = [1, 0, 2]

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(positions.indices, id: \.self) { index in
                    let value = positions[index]
                    Button { router.selection.setValue(Float(value)) } label: {
                        Text(value == 0 ? "OFF" : String(value))
                            .font(.system(size: 7, weight: .bold))
                            .offset(y: value == 0 ? 0 : 20)
                            .frame(width: 22, height: 40, alignment: .top)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(value == 0 ? "Filter off" : "Filter \(value)")
                        .accessibilityAddTraits(selection == value ? .isSelected : [])
                }
            }
            ConsoleEQKnob(value: .constant(selection == 1 ? -16 : selection == 2 ? 16 : 0), showsScale: false)
                .position(x: 33, y: 24)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .frame(width: 66, height: 40)
        .contentShape(Rectangle())
        // Keep the three assignment buttons tappable while still allowing the
        // whole control to be swept vertically like the original selector.
        .simultaneousGesture(DragGesture(minimumDistance: 4)
            .onChanged { event in
                if dragOrigin == nil { dragOrigin = selection == 1 ? 0 : selection == 2 ? 2 : 1 }
                let steps = Int((-event.translation.height / 12).rounded())
                let index = min(2, max(0, (dragOrigin ?? 1) + steps))
                router.selection.setValue(Float(positions[index]))
            }
            .onEnded { _ in dragOrigin = nil })
        .animation(.easeOut(duration: 0.08), value: selection)
        .onAppear { selection = Int(router.selection.value) }
        .onReceive(router.changes) { _ in selection = Int(router.selection.value) }
        .accessibilityElement(children: .contain)
        .accessibilityValue(selection == 0 ? "Off" : "Filter \(selection)")
        .help("Filter 1 / OFF / Filter 2 · click a label or drag the knob vertically")
    }
}
