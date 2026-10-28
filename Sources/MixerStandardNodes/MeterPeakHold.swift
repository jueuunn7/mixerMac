import Foundation

public struct MeterPeakHold {
    public private(set) var level: Float = 0
    public init() {}

    private var holdUntil: TimeInterval = 0
    private var lastUpdate: TimeInterval = 0

    public mutating func update(_ input: Float, now: TimeInterval) {
        let input = min(1, max(0, input))
        let releaseTime = max(0, now - max(lastUpdate, holdUntil))
        if input > 0 && input >= level {
            level = input
            holdUntil = now + 1.5
        } else if releaseTime > 0 {
            level = max(input, level - Float(releaseTime) * 0.35)
        }
        lastUpdate = now
    }
}
