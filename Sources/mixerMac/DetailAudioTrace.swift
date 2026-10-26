import SwiftUI

private typealias TraceState<Value> = SwiftUI.State<Value>

/// Interpolate display snapshots at a capped frame rate; never increase FFT work.
struct DetailAnimatedTrace: View {
    let levels: [Double]
    let plot: CGRect
    var history = false
    var fillOpacity = 0.15
    var strokeOpacity = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @TraceState private var previous: [Double] = []
    @TraceState private var target: [Double] = []
    @TraceState private var started = Date.distantPast

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let displayed = reduceMotion ? levels : interpolated(at: context.date)
            let line = DetailAudioTrace(levels: displayed, plot: plot, history: history)
            DetailAudioTrace(levels: displayed, plot: plot, history: history, filled: true)
                .fill(.green.opacity(fillOpacity))
                .overlay { line.stroke(.green.opacity(strokeOpacity), lineWidth: history ? 1.2 : 1) }
        }
        .allowsHitTesting(false)
        .onChange(of: levels) { old, new in
            previous = target.isEmpty ? old : interpolated(at: .now)
            target = new
            started = .now
        }
    }

    private func interpolated(at date: Date) -> [Double] {
        guard !target.isEmpty, previous.count == target.count else { return levels }
        let fraction = min(1, max(0, date.timeIntervalSince(started) / 0.15))
        return zip(previous, target).map { $0 + ($1 - $0) * fraction }
    }
}

struct DetailAudioTrace: Shape {
    let levels: [Double]
    let plot: CGRect
    var history = false
    var filled = false

    func path(in _: CGRect) -> Path {
        let points = levels.enumerated().map { index, db in
            let fraction = history ? Double(index) / Double(max(1, levels.count - 1)) : (Double(index) + 0.5) / Double(levels.count)
            return CGPoint(x: plot.minX + plot.width * fraction,
                y: plot.minY - plot.height * min(0, max(-90, db)) / 90)
        }
        guard let first = points.first, let last = points.last else { return Path() }
        return Path { path in
            if filled { path.move(to: CGPoint(x: plot.minX, y: plot.maxY)); path.addLine(to: first) }
            else { path.move(to: first) }
            // A monotone horizontal tangent preserves measured extrema and
            // rounds each transition without spline overshoot or fake peaks.
            for index in 1..<points.count {
                let previous = points[index - 1], current = points[index]
                let middle = (previous.x + current.x) / 2
                path.addCurve(to: current, control1: CGPoint(x: middle, y: previous.y),
                    control2: CGPoint(x: middle, y: current.y))
            }
            if filled {
                path.addLine(to: CGPoint(x: last.x, y: plot.maxY))
                path.closeSubpath()
            }
        }
    }
}

struct SpectrumDisplaySmoother {
    private(set) var values = [Float](repeating: -90, count: SpectrumAnalyzer.pointCount)
    mutating func update(_ measured: [Float], smoothness: Double = 0.5) -> [Float] {
        guard measured.count == values.count else { return values }
        for index in values.indices {
            let target = min(0, max(-90, measured[index]))
            let amount = min(1, max(0, smoothness))
            let weight = Float(target > values[index] ? 1 - 0.85 * amount : 1 - 0.95 * amount)
            values[index] += (target - values[index]) * weight
        }
        return values
    }
}
