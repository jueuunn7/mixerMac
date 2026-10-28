import Foundation

public enum StereoWidth {
    public static func clamped(_ value: Float) -> Float { value.isFinite ? min(2, max(0, value)) : 1 }
    public static func quantized(_ value: Float) -> Float { (clamped(value) * 100).rounded() / 100 }
    public static func label(_ value: Float) -> String { "\(Int((clamped(value) * 100).rounded()))%" }
}
