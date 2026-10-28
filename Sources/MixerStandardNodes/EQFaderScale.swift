import Foundation

public enum EQFaderScale {
    public static func position(for gain: Float) -> Float { (min(24, max(-24, gain)) + 24) / 48 }
    public static func gain(at position: Float) -> Float {
        let gain = min(1, max(0, position)) * 48 - 24
        return abs(gain) < 0.25 ? 0 : (gain * 10).rounded() / 10
    }
}
