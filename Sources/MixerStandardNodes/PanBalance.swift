import Foundation

public enum PanBalance {
    public static func clamped(_ value: Float) -> Float {
        value.isFinite ? min(1, max(-1, value)) : 0
    }
    public static func label(_ value: Float) -> String {
        let percentage = Int((abs(clamped(value)) * 100).rounded())
        return percentage == 0 ? "C" : "\(value < 0 ? "L" : "R") \(percentage)"
    }
    public static func quantized(_ value: Float) -> Float { (clamped(value) * 100).rounded() / 100 }
}
