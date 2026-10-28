import Foundation

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
