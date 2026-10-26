import Foundation

enum MixerMeterScale {
    static let displayReferenceDB: Float = 14
    // Inclusive digital sample-peak thresholds, not analog VU or true-peak.
    static let channelWarningDB: Float = 10 // -4 dBFS; early warning, not clipping.
    static let masterPeakDB: Float = 14 // 0 dBFS; full scale.
    static let channel: [Float] = [channelWarningDB, 6, 3, 0, -3, -6, -10, -15, -20]
    static let master: [Float] = [masterPeakDB, 6, 3, 0, -3, -6, -10, -15, -20, -25, -35]
    // Software display reference: a -14 dBFS peak reads 0 on the faceplate.
    // This changes meter labels only; it never changes the audio gain.
    static func decibels(for normalizedLevel: Float) -> Float {
        normalizedLevel > 0 ? normalizedLevel * 60 - 60 + displayReferenceDB : -.infinity
    }
    static func label(_ value: Float) -> String {
        value > 0 ? "+\(Int(value))" : "\(Int(value))"
    }
}
