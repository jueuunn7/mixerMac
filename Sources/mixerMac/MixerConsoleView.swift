import MixerAudio
import MixerCore
import MixerStandardNodes
import SwiftUI
import AppKit

private typealias ConsoleState<Value> = SwiftUI.State<Value>

enum ConsoleLayout {
    static let stripHeight: CGFloat = 904
    static let windowWidth: CGFloat = 1000
    static let minimumWindowWidth: CGFloat = 960
    static let windowHeight: CGFloat = stripHeight + 16 + 61
    static let appFaderHeight: CGFloat = 187
    static let eqRowHeight: CGFloat = 45
    static let stripWidth: CGFloat = 150
    static let masterStereoRowHeight: CGFloat = 44
    static let masterMeterHeight: CGFloat = 160
    static let stripTopInset: CGFloat = 12
    static let stripBottomInset: CGFloat = 10
    static let headerHeight: CGFloat = 35
    static let gainHeight: CGFloat = 53
    static let channelSpacing: CGFloat = 7
    static let channelControlsHeight: CGFloat = 108
    static let eqBankInset: CGFloat = 4
    static let masterSpacing: CGFloat = 5
    static let masterWaveformHeight: CGFloat = 50
}

private enum ConsolePalette {
    static let ink = Color(white: 0.13)
    static let secondary = Color(white: 0.32)
    static let accent = Color(red: 0.12, green: 0.38, blue: 0.56)
    static let blue = Color(red: 0.25, green: 0.70, blue: 0.94)
    static let amber = Color(red: 1, green: 0.72, blue: 0.15)
    static let green = Color(red: 0.43, green: 0.91, blue: 0.35)
    static let red = Color(red: 1, green: 0.16, blue: 0.12)
    static func meterColor(_ segment: Int) -> Color {
        segment >= 22 ? red : segment >= 20 ? amber : segment >= 16 ? blue : green
    }
}

struct MixerConsoleView: View {
    @StateObject private var mixer = MixerConsoleModel()
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(alignment: .top, spacing: 0) {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(Array(mixer.channels.enumerated()), id: \.element.id) { index, channel in
                                AppConsoleStrip(channel: channel, index: index + 1)
                            }
                            emptySlot
                        }
                        .padding(.horizontal, 8).padding(.vertical, 8)
                    }
                    MasterConsoleStrip(mixer: mixer).padding(.vertical, 8).padding(.trailing, 10)
            }
            .frame(height: ConsoleLayout.stripHeight + 16)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(ConsolePalette.ink)
        .background(LinearGradient(colors: [Color(white: 0.79), Color(white: 0.69)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .preferredColorScheme(.light)
        .task { mixer.start() }
        .onReceive(Timer.publish(every: 1.0 / 15, on: .main, in: .common).autoconnect()) { _ in mixer.tick() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in mixer.shutdown() }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            ConsoleScrew()
            Spacer()
            Label("OUTPUT", systemImage: "headphones").font(.system(size: 9, weight: .bold)).foregroundStyle(ConsolePalette.secondary)
            Picker("Output device", selection: Binding(get: { mixer.outputID }, set: { mixer.selectOutput($0) })) {
                ForEach(mixer.outputs) { output in Text(output.name).tag(output.id) }
            }.labelsHidden().frame(width: 210).disabled(mixer.isMixing)
            Button { mixer.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh audio apps and devices")
            Button { mixer.toggleMixing() } label: {
                Label {
                    Text("POWER")
                } icon: {
                    Image(systemName: "power")
                        .foregroundStyle(mixer.isMixing ? Color(red: 0.08, green: 0.48, blue: 0.2) : ConsolePalette.secondary)
                }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 15).padding(.vertical, 8)
                    .foregroundStyle(ConsolePalette.ink)
                    .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .stroke(mixer.isMixing ? Color(red: 0.08, green: 0.48, blue: 0.2) : .black.opacity(0.35), lineWidth: mixer.isMixing ? 2 : 1))
            }.buttonStyle(.plain).disabled((mixer.channels.isEmpty && !mixer.isMixing) || mixer.isBusy)
                .accessibilityLabel("Mixer power")
                .accessibilityValue(mixer.isMixing ? "On" : "Off")
                .help(mixer.status)
        }
        .padding(.horizontal, 22).frame(height: 61)
        .background(LinearGradient(colors: [.white.opacity(0.07), .black.opacity(0.1)], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.7)).frame(height: 1) }
    }

    private var emptySlot: some View {
        VStack(spacing: 14) {
            Image(systemName: "plus.circle").font(.system(size: 26, weight: .ultraLight))
            Text("APP CHANNEL").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1)
            Text("Play audio in an app.\nIts channel appears here.")
                .font(.system(size: 11)).multilineTextAlignment(.center).lineSpacing(5)
        }
        .foregroundStyle(ConsolePalette.secondary.opacity(0.65))
        .padding(.leading, 20).frame(width: 172, height: ConsoleLayout.stripHeight)
        .background(ConsoleChannelPlate(fillsSurface: false))
    }
}

struct AppConsoleStrip: View {
    @ObservedObject var channel: AppAudioChannel
    let index: Int
    @ConsoleState private var showingDetail = false

    var body: some View {
        VStack(spacing: ConsoleLayout.channelSpacing) {
            HStack(spacing: 10) {
                Text(channel.app.name)
                    .font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(channel.app.name)
            }.padding(.leading, 18).frame(height: ConsoleLayout.headerHeight)

            ConsolePrintedKnob(value: channel.core.equalizer.gain.binding, label: "TRIM", trim: true)
                .frame(height: ConsoleLayout.gainHeight).accessibilityLabel("\(channel.app.name) trim")

            VStack(spacing: 0) {
                ForEach(Array(EQSettings.frequencies.indices.reversed()), id: \.self) { band in
                    ConsolePrintedKnob(value: channel.core.equalizer.bands[band].gain.binding, label: Self.frequency(channel.settings.frequencies[band]))
                        .frame(height: ConsoleLayout.eqRowHeight)
                        .accessibilityLabel("\(channel.app.name) \(Self.frequency(channel.settings.frequencies[band])) gain")
                }
            }
            .padding(.vertical, ConsoleLayout.eqBankInset)
            .frame(maxWidth: .infinity)
            VStack(spacing: 8) {
                HStack(spacing: 20) {
                    ConsolePanControl(value: channel.core.pan.binding, compact: true)
                        .accessibilityLabel("\(channel.app.name) pan")
                    ConsoleWidthControl(value: channel.core.width.binding)
                        .accessibilityLabel("\(channel.app.name) stereo width")
                }
                HStack(spacing: 8) {
                    ConsoleButton(title: "MUTE", active: channel.isMuted, color: .red) { channel.isMuted.toggle() }
                    ConsoleButton(title: "SOLO", active: channel.isSolo, color: .yellow) { channel.isSolo.toggle() }
                }.frame(width: 116)
                HStack(spacing: 8) {
                    ConsoleResetButton {
                        channel.settings.gains = [Float](repeating: 0, count: EQSettings.frequencies.count)
                    }.accessibilityLabel("Reset \(channel.app.name) EQ").help("Reset this app's EQ")
                    Button("DETAIL") { showingDetail = true }
                        .buttonStyle(ConsolePushButtonStyle())
                        .accessibilityLabel("\(channel.app.name) Detail")
                        .help("Open \(channel.app.name) detail")
                }.frame(width: 116)
            }.frame(maxWidth: .infinity).frame(height: ConsoleLayout.channelControlsHeight)

            HStack(alignment: .top, spacing: 8) {
                LiveConsoleMeter(metrics: channel.metrics).frame(width: 36, height: 137).padding(.top, 14)
                ConsoleFader(value: channel.core.volume.binding)
                    .accessibilityLabel("\(channel.app.name) channel volume")
            }.frame(height: ConsoleLayout.appFaderHeight).padding(.trailing, 44)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.top, ConsoleLayout.stripTopInset).padding(.bottom, ConsoleLayout.stripBottomInset)
        .frame(width: ConsoleLayout.stripWidth, height: ConsoleLayout.stripHeight, alignment: .top)
        .background(ConsoleChannelPlate(channelNumber: index))
        .sheet(isPresented: $showingDetail) { ChannelDetailView(channel: channel) }
    }

    private static func frequency(_ frequency: Float) -> String {
        if frequency >= 1000 { return String(format: frequency.truncatingRemainder(dividingBy: 1000) == 0 ? "%.0fk" : "%.1fk", frequency / 1000) }
        return String(format: "%.0f", frequency)
    }
}

struct MasterConsoleStrip: View {
    @ObservedObject var mixer: MixerConsoleModel
    @ConsoleState private var showingDetail = false
    var body: some View {
        VStack(spacing: ConsoleLayout.masterSpacing) {
            HStack {
                ConsoleScrew()
                Text("MASTER").font(.system(size: 11, weight: .bold)).tracking(0.5)
                Spacer(minLength: 0)
            }.frame(height: ConsoleLayout.headerHeight)

            ConsolePrintedKnob(value: mixer.core.master.equalizer.gain.binding, label: "GAIN", trim: true)
                .accessibilityLabel("Master gain")

            MasterWaveformView(metrics: mixer.masterWaveform).frame(height: ConsoleLayout.masterWaveformHeight)

            VStack(spacing: 0) {
                ForEach(Array(BusEQSettings.frequencies.indices.reversed()), id: \.self) { band in
                    ConsolePrintedKnob(value: mixer.core.master.equalizer.bands[band].gain.binding, label: frequencyLabel(mixer.masterEQ.bandFrequencies[band]))
                        .frame(height: ConsoleLayout.eqRowHeight)
                        .accessibilityLabel("Master \(BusEQSettings.labels[band]) EQ")
                }
            }
            .padding(.vertical, ConsoleLayout.eqBankInset)
            Spacer(minLength: 0)

            VStack(spacing: 6) {
                HStack(spacing: 20) {
                    ConsolePanControl(value: mixer.core.master.pan.binding, compact: true)
                        .accessibilityLabel("Master pan")
                    ConsoleWidthControl(value: mixer.core.master.width.binding)
                }
                HStack(spacing: 8) {
                    ConsoleResetButton {
                        mixer.masterEQ.gains = [Float](repeating: 0, count: BusEQSettings.frequencies.count)
                    }.accessibilityLabel("Reset master EQ").help("Reset master EQ")
                    Button("DETAIL") { showingDetail = true }
                        .buttonStyle(ConsolePushButtonStyle())
                        .accessibilityLabel("Master Detail")
                        .help("Open master detail")
                }.frame(width: 116)
            }
            .frame(maxWidth: .infinity).frame(height: ConsoleLayout.masterStereoRowHeight + 30)
            LiveStereoMasterMeter(left: mixer.masterLeftMetrics, right: mixer.masterRightMetrics)
                .frame(height: ConsoleLayout.masterMeterHeight).padding(.horizontal, 14)
            Text("MASTER OUT")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(ConsolePalette.secondary).frame(height: 9)
                .padding(.top, 4)
        }
        .padding(.horizontal, 8).padding(.top, ConsoleLayout.stripTopInset).padding(.bottom, ConsoleLayout.stripBottomInset)
        .frame(width: ConsoleLayout.stripWidth, height: ConsoleLayout.stripHeight, alignment: .top)
        .background(ConsoleChannelPlate())
        .sheet(isPresented: $showingDetail) { MasterDetailView(mixer: mixer) }
    }

    private func frequencyLabel(_ value: Float) -> String {
        if value >= 1000 { return String(format: value.truncatingRemainder(dividingBy: 1000) == 0 ? "%.0fk" : "%.1fk", value / 1000) }
        return String(format: value.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", value)
    }
}

struct ConsoleResetButton: View {
    let action: () -> Void
    var body: some View {
        Button("RESET", action: action).buttonStyle(ConsolePushButtonStyle())
    }
}

struct ConsoleScrew: View {
    var body: some View {
        Circle().fill(Color(white: 0.11)).frame(width: 9, height: 9)
            .overlay(Rectangle().fill(.black).frame(width: 6, height: 1).rotationEffect(.degrees(-35)))
            .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5))
    }
}

struct ConsoleFader: View {
    @Binding var value: Float
    @ConsoleState private var initial: Float? = nil
    var body: some View {
        GeometryReader { proxy in
            let travel = max(1, proxy.size.height - 40)
            ZStack {
                ForEach(0..<17) { index in
                    Rectangle().fill(ConsolePalette.ink.opacity(index == 6 ? 0.9 : 0.45))
                        .frame(width: index % 4 == 0 ? 15 : 9, height: index % 4 == 0 ? 1.2 : 0.7)
                        .offset(x: -16, y: -travel / 2 + travel * CGFloat(index) / 16)
                }
                Text("∞").font(.system(size: 12, weight: .medium)).foregroundStyle(ConsolePalette.ink)
                    .offset(x: -18, y: travel / 2 + 11)
                Rectangle().fill(.black.opacity(0.95)).frame(width: 7, height: max(1, proxy.size.height - 22))
                ForEach([-1.0, 1.0], id: \.self) { edge in
                    Circle().fill(Color(white: 0.07)).frame(width: 8, height: 8)
                        .offset(y: CGFloat(edge) * (proxy.size.height / 2 - 4))
                }
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.035), Color(white: 0.14)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 40, height: 17)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.black, lineWidth: 1))
                    .overlay(Rectangle().fill(.white.opacity(0.95)).frame(height: 2))
                    .shadow(color: .black.opacity(0.55), radius: 2, x: 1, y: 2)
                    .offset(y: travel * (0.5 - CGFloat(FaderScale.position(for: value))))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle().inset(by: -10))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { event in
                    if initial == nil { initial = FaderScale.position(for: value) }
                    value = FaderScale.gain(at: (initial ?? 0.5) - Float(event.translation.height / travel))
                }.onEnded { _ in initial = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = 1 })
            .accessibilityLabel("Volume")
            .help("Top = 0 dB maximum · bottom = muted · double-click resets to maximum")
            .accessibilityValue(value == 0 ? "Muted" : String(format: "%+.1f dB", 20 * log10(value)))
            .accessibilityAdjustableAction { direction in
                let step: Float = direction == .increment ? 0.02 : -0.02
                value = FaderScale.gain(at: FaderScale.position(for: value) + step)
            }
        }
    }
}

struct ConsoleLevelMeter: View {
    let level: Float
    let peak: Float
    var body: some View {
        Canvas { context, size in
            let currentDB = MixerMeterScale.decibels(for: level)
            let peakDB = MixerMeterScale.decibels(for: peak)
            let heldIndex = MixerMeterScale.channel.firstIndex(where: { peakDB >= $0 })
            for (index, threshold) in MixerMeterScale.channel.enumerated() {
                let y = size.height * (CGFloat(index) + 0.5) / 9
                let label = Text(MixerMeterScale.label(threshold)).font(.system(size: 7, weight: .medium)).foregroundStyle(ConsolePalette.ink)
                context.draw(label, at: CGPoint(x: size.width - 14, y: y), anchor: .trailing)
                let rect = CGRect(x: size.width - 8, y: y - 3.5, width: 7, height: 7)
                let color = threshold >= 10 ? ConsolePalette.red : threshold >= 0 ? ConsolePalette.blue : ConsolePalette.green
                let held = heldIndex == index
                let path = Path(ellipseIn: rect)
                context.fill(path, with: .color(currentDB >= threshold || held ? color : Color(white: 0.11)))
                if held { context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 0.7) }
            }
        }
        .accessibilityLabel("Live signal level")
        .accessibilityValue("\(Int(level * 100)) percent, held peak \(Int(peak * 100)) percent")
        .help("Post-EQ / pre-fader · 0 = −14 dBFS · peak hold 1.5 s")
    }
}

struct LiveStereoMasterMeter: View {
    @ObservedObject var left: ChannelAudioMetrics
    @ObservedObject var right: ChannelAudioMetrics
    var body: some View {
        Canvas { context, size in
            let pitch = (size.height - 18) / 11
            let levels = [left.level, right.level].map { MixerMeterScale.decibels(for: $0) }
            let peaks = [left.heldPeak, right.heldPeak].map { MixerMeterScale.decibels(for: $0) }
            for (index, threshold) in MixerMeterScale.master.enumerated() {
                let y = pitch * (CGFloat(index) + 0.5)
                let label = index == 0 ? "PK!" : MixerMeterScale.label(threshold)
                context.draw(Text(label).font(.system(size: 8, weight: .medium)).foregroundStyle(ConsolePalette.ink), at: CGPoint(x: size.width / 2, y: y))
                for side in 0..<2 {
                    let x = side == 0 ? CGFloat(7) : size.width - 7
                    let path = Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8))
                    let held = MixerMeterScale.master.firstIndex(where: { peaks[side] >= $0 }) == index
                    let color = index == 0 ? ConsolePalette.red : threshold >= 0 ? ConsolePalette.blue : ConsolePalette.green
                    context.fill(path, with: .color(levels[side] >= threshold || held ? color : Color(white: 0.11)))
                    if held { context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 0.7) }
                }
            }
            for (text, x) in [("L", CGFloat(7)), ("MIX", size.width / 2), ("R", size.width - 7)] {
                context.draw(Text(text).font(.system(size: 8, weight: .bold)).foregroundStyle(ConsolePalette.ink), at: CGPoint(x: x, y: size.height - 6))
            }
        }
        .accessibilityLabel("Master stereo levels")
        .accessibilityValue("Left \(Int(left.level * 100)) percent, Right \(Int(right.level * 100)) percent")
        .help("Independent left/right audio · display reference 0 = −14 dBFS")
    }
}

struct LiveConsoleMeter: View {
    @ObservedObject var metrics: ChannelAudioMetrics
    var body: some View { ConsoleLevelMeter(level: metrics.level, peak: metrics.heldPeak) }
}

struct ConsoleButton: View {
    let title: String
    let active: Bool
    let color: Color
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
        .buttonStyle(ConsolePushButtonStyle(active: active, color: color))
        .accessibilityLabel(title)
        .accessibilityValue(active ? "On" : "Off")
    }
}

private struct ConsolePushButtonStyle: ButtonStyle {
    var active = false
    var color = ConsolePalette.blue
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(LinearGradient(colors: configuration.isPressed
                    ? [Color(white: 0.035), Color(white: 0.13)]
                    : [Color(white: 0.23), Color(white: 0.035)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(active || configuration.isPressed ? color : .black.opacity(0.6), lineWidth: 3))
                .shadow(color: .black.opacity(0.3), radius: 1, y: configuration.isPressed ? 0 : 1)
            configuration.label
                .font(.system(size: 7, weight: .black)).fixedSize()
        }
        .foregroundStyle(ConsolePalette.ink)
        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 24)
        .contentShape(Rectangle())
        .offset(y: configuration.isPressed ? 1 : 0)
        .opacity(enabled ? 1 : 0.5)
    }
}
