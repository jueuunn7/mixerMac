import MixerAudio
import MixerCore
import MixerStandardNodes
import SwiftUI

private typealias DetailState<Value> = SwiftUI.State<Value>

struct ChannelDetailView: View {
    @ObservedObject var channel: AppAudioChannel
    var body: some View {
        EQDetailView(title: channel.app.name, settings: $channel.settings,
            isMaster: false, isProcessing: channel.isProcessing,
            feed: channel.isProcessing ? channel.postEQ : channel.input,
            width: channel.core.width.binding)
    }
}

struct MasterDetailView: View {
    @ObservedObject var mixer: MixerConsoleModel
    var body: some View {
        EQDetailView(title: "Master EQ", settings: Binding(
            get: { mixer.masterEQ.detailSettings },
            set: { mixer.masterEQ.detailSettings = $0 }),
            isMaster: true, isProcessing: mixer.isMixing, feed: mixer.masterFeed,
            width: mixer.core.master.width.binding)
    }
}

private struct EQDetailView: View {
    let title: String
    @Binding var settings: ChannelSettings
    let isMaster: Bool
    let isProcessing: Bool
    let feed: PCMFeed
    var width: Binding<Float>? = nil
    @Environment(\.dismiss) private var dismiss
    @StateObject private var detail = ChannelDetailModel()
    @DetailState private var selectedBand = 0
    @DetailState private var showingFaders = true
    // Keep the same publisher while graph drags rebuild the view at pointer rate.
    @DetailState private var analysisTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 20, weight: .semibold))
                    Text(isMaster ? "MASTER DETAIL · 10-BAND PARAMETRIC EQ" : "CHANNEL DETAIL · 10-BAND PARAMETRIC EQ").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(isProcessing ? "LIVE" : "PREVIEW · POWER ON TO APPLY")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(isProcessing ? Color.green : Color.secondary)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Text("EQ RESPONSE").font(.system(size: 11, weight: .bold)).tracking(1)
                Text("Drag bands · cyan EQ / green smoothed audio").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if let width { DetailWidthControl(value: width) }
                DetailPanControl(value: $settings.pan)
                Text(isMaster ? "GAIN" : "TRIM").font(.system(size: 10, weight: .bold))
                DetailNumberField(value: Binding(get: { Double(settings.trimDB) }, set: {
                    guard $0.isFinite else { return }; settings.trimDB = Float(min(24, max(-24, $0)))
                }), label: isMaster ? "Master gain" : "Channel trim", digits: 1).frame(width: 65)
                Text("dB").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            DetailResponsePlot(settings: $settings, detail: detail, selectedBand: $selectedBand)
                .frame(height: 210)
            HStack(spacing: 12) {
                DetailSignalPlot(detail: detail, history: false)
                DetailSignalPlot(detail: detail, history: true)
            }.frame(height: 150)
            HStack {
                Text("BAND SETTINGS").font(.system(size: 11, weight: .bold)).tracking(1)
                Text("Gain 0.1 dB · bandwidth in octaves").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Picker("EQ editor", selection: $showingFaders) {
                    Text("Faders").tag(true)
                    Text("Table").tag(false)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
                Button("Reset EQ") {
                    settings.gains = Array(repeating: 0, count: 10)
                    settings.frequencies = EQSettings.frequencies
                    settings.bandwidths = Array(repeating: 1, count: 10)
                }.controlSize(.small)
            }
            Group {
                if showingFaders {
                    DetailFaderBank(settings: $settings, selectedBand: $selectedBand)
                } else { settingsTable }
            }.frame(height: 282)
            HStack {
                Circle().fill(detail.receivingAudio ? .green : .gray).frame(width: 5, height: 5)
                Text(isMaster
                    ? (isProcessing ? "Measured master output · after channel faders and master EQ" : "Measured system playback · master EQ preview until Mixer starts")
                    : (isProcessing ? "Measured after channel EQ / before fader, mute and master EQ" : "Measured app input · EQ response is a preview until the mixer starts"))
                Spacer()
                Text("\(Int(detail.sampleRate)) Hz · settings saved automatically")
            }.font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 880)
        .background(LinearGradient(colors: [Color(white: 0.84), Color(white: 0.73)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .foregroundStyle(Color(white: 0.13)).preferredColorScheme(.light)
        .onAppear { detail.tick(settings: settings, feed: feed, isProcessing: isProcessing) }
        .onReceive(analysisTimer) { _ in detail.tick(settings: settings, feed: feed, isProcessing: isProcessing) }
        .onChange(of: settings) { _, _ in
            detail.refreshResponse(settings: settings)
        }
    }

    private var settingsTable: some View {
        DetailBandTable(settings: $settings, selectedBand: $selectedBand, upperFrequency: detail.upperFrequency)
    }
}

private struct DetailBandTable: View {
    @Binding var settings: ChannelSettings
    @Binding var selectedBand: Int
    let upperFrequency: Double

    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 3) {
            GridRow {
                Text("BAND").frame(width: 38, alignment: .leading)
                Text("FREQUENCY · Hz").frame(width: 105)
                Text("GAIN · dB").frame(width: 85)
                Text("BW · oct").frame(width: 80)
                Text("−24 dB                    0                    +24 dB").frame(maxWidth: .infinity)
                Text("RESET").frame(width: 38)
            }.font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary).frame(height: 19)
            ForEach(0..<10) { band in
                GridRow {
                    Button(String(format: "%02d", band + 1)) { selectedBand = band }
                        .buttonStyle(.plain).font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(selectedBand == band ? Color.blue : Color.secondary)
                        .frame(width: 38, height: 23, alignment: .leading)
                    DetailNumberField(value: Binding(get: { Double(settings.frequencies[band]) }, set: {
                        guard $0.isFinite else { return }
                        settings.frequencies[band] = Float(min(upperFrequency, max(20, $0)))
                    }), label: "Band \(band + 1) frequency", digits: 1).frame(width: 105)
                    DetailNumberField(value: Binding(get: { Double(settings.gains[band]) }, set: {
                        setDetailGain(Float($0), band: band, settings: $settings)
                    }), label: "Band \(band + 1) gain", digits: 1).frame(width: 85)
                    DetailNumberField(value: Binding(get: { Double(settings.bandwidths[band]) }, set: {
                        guard $0.isFinite else { return }
                        settings.bandwidths[band] = Float(min(4, max(0.05, $0)))
                    }), label: "Band \(band + 1) bandwidth", digits: 2).frame(width: 80)
                    Slider(value: Binding(get: { Double(settings.gains[band]) }, set: { setDetailGain(Float($0), band: band, settings: $settings) }), in: -24...24)
                        .accessibilityLabel("Band \(band + 1) gain slider").controlSize(.mini)
                    Button { setDetailGain(0, band: band, settings: $settings) } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.plain).frame(width: 38).help("Reset band \(band + 1) gain")
                }
                .padding(.horizontal, 5)
                .background(selectedBand == band ? Color.white.opacity(0.28) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
            }
        }
    }
}

struct DetailNumberField: View {
    @Binding var value: Double
    let label: String
    let digits: Int
    @DetailState private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField(label, text: $draft)
            .labelsHidden().multilineTextAlignment(.trailing)
            .font(.system(size: 10, design: .monospaced)).textFieldStyle(.roundedBorder)
            .accessibilityLabel(label)
            .focused($focused)
            .onAppear { draft = formattedValue }
            .onChange(of: value) { _, _ in draft = formattedValue }
            .onChange(of: focused) { _, active in if !active { commit() } }
            .onSubmit { commit() }
            .onDisappear { if focused { commit() } }
    }

    private var formattedValue: String {
        value.formatted(.number.precision(.fractionLength(digits)).grouping(.never))
    }

    private func commit() {
        let normalized = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-")
        if let number = Double(normalized), number.isFinite { value = number }
        draft = formattedValue
    }
}

private struct DetailResponsePlot: View {
    @Binding var settings: ChannelSettings
    @ObservedObject var detail: ChannelDetailModel
    @Binding var selectedBand: Int
    @DetailState private var dragStart: (frequency: Float, gain: Float)?
    private var extent: Double { max(24, ceil(((detail.response.map(abs).max() ?? 0) + 6) / 12) * 12) }

    var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(x: 42, y: 22, width: proxy.size.width - 82, height: proxy.size.height - 49)
            ZStack {
                DetailAnimatedTrace(levels: detail.spectrum.map(Double.init), plot: rect,
                    fillOpacity: 0.12, strokeOpacity: 0.75)
                Canvas { context, _ in
                    // Audio and filter gain use separate, explicitly labelled
                    // scales. Both share the same logarithmic frequency axis.
                    for db in [0.0, -30, -60, -90] {
                        context.draw(Text(String(format: "%.0f", db)).font(.system(size: 8, design: .monospaced)).foregroundStyle(.green.opacity(0.7)),
                            at: CGPoint(x: rect.maxX + 20, y: rect.minY - rect.height * db / 90))
                    }
                    for value in [-extent, -extent / 2, 0, extent / 2, extent] {
                        let y = rect.midY - rect.height * value / (extent * 2)
                        var line = Path(); line.move(to: CGPoint(x: rect.minX, y: y)); line.addLine(to: CGPoint(x: rect.maxX, y: y))
                        context.stroke(line, with: .color(.white.opacity(value == 0 ? 0.3 : 0.09)), lineWidth: 1)
                        context.draw(Text(String(format: "%+.0f", value)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.gray), at: CGPoint(x: 20, y: y))
                    }
                    for frequency in [20.0, 100, 1000, 10_000, detail.upperFrequency] {
                        let x = xPosition(frequency, rect: rect)
                        var line = Path(); line.move(to: CGPoint(x: x, y: rect.minY)); line.addLine(to: CGPoint(x: x, y: rect.maxY))
                        context.stroke(line, with: .color(.white.opacity(0.07)), lineWidth: 1)
                        let label = frequency >= 1000 ? String(format: "%.0fk", frequency / 1000) : String(format: "%.0f", frequency)
                        context.draw(Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(.gray), at: CGPoint(x: x, y: rect.maxY + 15))
                    }
                    var curve = Path()
                    for index in detail.response.indices {
                        let point = CGPoint(x: rect.minX + rect.width * Double(index) / 255,
                            y: rect.midY - rect.height * detail.response[index] / (extent * 2))
                        if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                    }
                    context.stroke(curve, with: .color(.cyan), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                }
                ForEach(0..<min(10, detail.bandResponse.count), id: \.self) { band in
                    Circle().fill(selectedBand == band ? Color.white : Color.cyan)
                        .frame(width: selectedBand == band ? 10 : 8, height: selectedBand == band ? 10 : 8)
                        .overlay(Circle().stroke(.black.opacity(0.7), lineWidth: 1))
                        .frame(width: 24, height: 24).contentShape(Circle())
                        .overlay(alignment: .top) {
                            Text(bandLabel(band))
                                .font(.system(size: 8, weight: selectedBand == band ? .bold : .medium, design: .monospaced))
                                .foregroundStyle(selectedBand == band ? .white : .cyan)
                                .fixedSize().padding(.horizontal, 3).padding(.vertical, 2)
                                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 2))
                                .offset(y: -15).allowsHitTesting(false)
                        }
                        .position(x: xPosition(Double(settings.frequencies[band]), rect: rect),
                            y: rect.midY - rect.height * detail.bandResponse[band] / (extent * 2))
                        .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                            selectedBand = band
                            if dragStart == nil { dragStart = (settings.frequencies[band], settings.gains[band]) }
                            guard let start = dragStart else { return }
                            let frequency = Float(min(detail.upperFrequency, max(20,
                                Double(start.frequency) * pow(detail.upperFrequency / 20, event.translation.width / rect.width))))
                            let gain = start.gain - Float(event.translation.height / rect.height * extent * 2)
                            setDetailBand(band, frequency: frequency, gain: gain, settings: $settings)
                        }.onEnded { _ in dragStart = nil })
                        .onTapGesture { selectedBand = band }
                        .accessibilityLabel("Select EQ band \(band + 1)")
                        .help(String(format: "Band %d · %.1f Hz · %+.1f dB", band + 1, settings.frequencies[band], settings.gains[band]))
                }
                if let error = detail.responseError { Text(error).font(.caption).foregroundStyle(.orange) }
                Text("dB").font(.system(size: 8, design: .monospaced)).foregroundStyle(.gray).position(x: 18, y: 7)
                Text("dBFS").font(.system(size: 8, design: .monospaced)).foregroundStyle(.green.opacity(0.7))
                    .position(x: rect.maxX + 20, y: 7)
            }
        }
        .background(Color(white: 0.075), in: RoundedRectangle(cornerRadius: 5))
        .accessibilityLabel("Actual channel EQ frequency response")
    }

    private func xPosition(_ frequency: Double, rect: CGRect) -> Double {
        rect.minX + rect.width * min(1, max(0, log(frequency / 20) / log(detail.upperFrequency / 20)))
    }

    private func bandLabel(_ band: Int) -> String {
        let frequency = settings.frequencies[band]
        let label = frequency >= 1000 ? String(format: "%.1fk", frequency / 1000) : String(format: frequency < 100 ? "%.1f" : "%.0f", frequency)
        return "\(band + 1) · \(label)"
    }
}

private struct DetailSignalPlot: View {
    @ObservedObject var detail: ChannelDetailModel
    let history: Bool
    private var recentPeak: Double { detail.history.max() ?? -90 }
    private var ceiling: Double { history ? max(24, ceil(max(0, recentPeak) / 12) * 12) : 0 }

    private func formattedPeak(_ value: Double) -> String {
        value <= -90 ? "−∞" : String(format: "%+.1f", value)
    }
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(history ? "SIGNAL LEVEL · 15 s" : "LIVE SPECTRUM · SMOOTH").font(.system(size: 10, weight: .bold)).tracking(0.5)
                Spacer()
                Text(history ? "\(formattedPeak(detail.peakDB)) · MAX \(formattedPeak(recentPeak)) dBFS" : (detail.receivingAudio ? "LIVE" : "NO SIGNAL"))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(history && recentPeak > 0 ? Color.red : Color.secondary)
            }
            GeometryReader { proxy in
                let rect = CGRect(x: 35, y: 10, width: proxy.size.width - 47, height: proxy.size.height - 30)
                let values = history ? detail.history : detail.spectrum.map(Double.init)
                ZStack {
                DetailAnimatedTrace(levels: values, plot: rect, history: history, ceiling: ceiling)
                Canvas { context, _ in
                if history {
                    let zeroY = DetailAudioTrace.yPosition(0, plot: rect, ceiling: ceiling)
                    context.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: zeroY - rect.minY)),
                        with: .color(.red.opacity(0.08)))
                }
                let marksDB: [Double] = history ? [ceiling, ceiling / 2, 0, -30, -60, -90] : [0, -30, -60, -90]
                for db in marksDB {
                    let y = DetailAudioTrace.yPosition(db, plot: rect, ceiling: ceiling)
                    var line = Path(); line.move(to: CGPoint(x: rect.minX, y: y)); line.addLine(to: CGPoint(x: rect.maxX, y: y))
                    context.stroke(line, with: .color(history && db == 0 ? .orange.opacity(0.8) : .white.opacity(0.1)), lineWidth: history && db == 0 ? 1 : 0.6)
                    context.draw(Text(String(format: db > 0 ? "+%.0f" : "%.0f", db))
                        .font(.system(size: 8, design: .monospaced)).foregroundStyle(history && db >= 0 ? Color.orange : Color.gray), at: CGPoint(x: 16, y: y))
                }
                let marks: [(String, Double)] = history ? [("−15 s", 0), ("−7.5 s", 0.5), ("NOW", 1)] : [("20 Hz", 0), ("1k", log(1000 / 20) / log(detail.upperFrequency / 20)), (String(format: "%.0fk", detail.upperFrequency / 1000), 1)]
                for (label, position) in marks {
                    context.draw(Text(label).font(.system(size: 8, design: .monospaced)).foregroundStyle(.gray), at: CGPoint(x: rect.minX + rect.width * position, y: rect.maxY + 11))
                }
                }
                }
            }.background(Color(white: 0.075), in: RoundedRectangle(cornerRadius: 5))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(history ? "Measured signal peak history, dBFS" : "Measured audio frequency spectrum, dBFS")
        .accessibilityValue(detail.receivingAudio ? String(format: "Peak %.1f dBFS", detail.peakDB) : "No audio signal")
    }
}
