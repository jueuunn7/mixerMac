import SwiftUI

struct WaveformBin: Equatable {
    let minimum: Float
    let maximum: Float
}

enum WaveformEnvelope {
    static let binCount = 96
    static let silence = Array(repeating: WaveformBin(minimum: 0, maximum: 0), count: binCount)

    static func bins(left: [Float], right: [Float]) -> [WaveformBin] {
        let count = min(left.count, right.count)
        guard count >= binCount else { return silence }
        return (0..<binCount).map { bin in
            var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
            for sample in (bin * count / binCount)..<((bin + 1) * count / binCount) {
                let l = left[sample].isFinite ? left[sample] : 0
                let r = right[sample].isFinite ? right[sample] : 0
                low = min(low, min(l, r))
                high = max(high, max(l, r))
            }
            return WaveformBin(minimum: low, maximum: high)
        }
    }

    static func smoothed(previous: [WaveformBin], next: [WaveformBin], amount: Double) -> [WaveformBin] {
        guard previous.count == next.count else { return next }
        let weight = Float(1 - 0.94 * min(1, max(0, amount)))
        return zip(previous, next).map { old, new in
            WaveformBin(minimum: old.minimum + (new.minimum - old.minimum) * weight,
                maximum: old.maximum + (new.maximum - old.maximum) * weight)
        }
    }
}

@MainActor
final class MasterWaveformMetrics: ObservableObject {
    @Published private(set) var bins = WaveformEnvelope.silence
    private var sequence: UInt64?

    func update(feed: PCMFeed, enabled: Bool) {
        guard enabled else {
            if bins != WaveformEnvelope.silence { bins = WaveformEnvelope.silence }
            sequence = nil
            return
        }
        guard let frame = feed.snapshot(consumingPeaks: false) else {
            // A nonblocking read can miss one callback. Fade the display
            // rather than flashing to a flat line on that single miss.
            let faded = WaveformEnvelope.smoothed(previous: bins, next: WaveformEnvelope.silence,
                amount: WaveformDisplaySettings.smoothness)
            if faded != bins { bins = faded }
            return
        }
        guard frame.sequence != sequence else { return }
        sequence = frame.sequence
        let next = WaveformEnvelope.smoothed(previous: bins,
            next: WaveformEnvelope.bins(left: frame.left, right: frame.right),
            amount: WaveformDisplaySettings.smoothness)
        if next != bins { bins = next }
    }
}

struct MasterWaveformView: View {
    @ObservedObject var metrics: MasterWaveformMetrics
    var body: some View {
        Canvas { context, size in
            let area = CGRect(x: 5, y: 5, width: max(1, size.width - 10), height: max(1, size.height - 10))
            var baseline = Path()
            baseline.move(to: CGPoint(x: area.minX, y: area.midY))
            baseline.addLine(to: CGPoint(x: area.maxX, y: area.midY))
            context.stroke(baseline, with: .color(.white.opacity(0.16)), lineWidth: 0.6)
            let bins = metrics.bins
            func point(_ index: Int, _ value: Float) -> CGPoint {
                CGPoint(x: area.minX + area.width * Double(index) / Double(max(1, bins.count - 1)),
                    y: area.midY - area.height * CGFloat(min(1, max(-1, value))) / 2)
            }
            var waveform = Path()
            for index in bins.indices {
                let next = point(index, bins[index].maximum)
                if index == 0 { waveform.move(to: next) } else { waveform.addLine(to: next) }
            }
            for index in bins.indices.reversed() { waveform.addLine(to: point(index, bins[index].minimum)) }
            waveform.closeSubpath()
            context.fill(waveform, with: .color(.cyan.opacity(0.35)))
            context.stroke(waveform, with: .color(.cyan.opacity(0.9)), lineWidth: 0.65)
        }
        .background(Color(white: 0.085), in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.black.opacity(0.45), lineWidth: 0.75))
        .help("Smoothed master output waveform · after channel faders and master EQ · fixed ±1 PCM scale")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Master output waveform")
    }
}
