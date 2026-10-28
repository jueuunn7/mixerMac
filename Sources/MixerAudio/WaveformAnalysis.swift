import Combine
import Foundation

public struct WaveformBin: Equatable, Sendable {
    public let minimum: Float
    public let maximum: Float
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
public final class MasterWaveformMetrics: ObservableObject {
    public init() {}
    @Published public private(set) var bins = WaveformEnvelope.silence
    private var sequence: UInt64?

    public func update(feed: PCMFeed, enabled: Bool) {
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
