import Foundation

public enum FaderScale {
    public static let maximumGain: Float = 1

    public static func position(for gain: Float) -> Float {
        sqrt(min(1, max(0, gain)))
    }

    public static func gain(at position: Float) -> Float {
        let position = min(1, max(0, position))
        if position <= 0.005 { return 0 }
        return position * position
    }
}
