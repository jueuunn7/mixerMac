import Combine
import Foundation

@MainActor
open class Parameter {
    public struct Unit: RawRepresentable, Hashable, Codable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let decibels = Self(rawValue: "decibels")
        public static let linearGain = Self(rawValue: "linearGain")
        public static let balance = Self(rawValue: "balance")
        public static let hertz = Self(rawValue: "hertz")
        public static let octaves = Self(rawValue: "octaves")
        public static let ratio = Self(rawValue: "ratio")
        public static let boolean = Self(rawValue: "boolean")
    }

    public let range: ClosedRange<Float>
    public let defaultValue: Float
    public let unit: Unit
    public let step: Float?
    public final private(set) var value: Float
    private let changed = PassthroughSubject<Void, Never>()
    public final var changes: AnyPublisher<Void, Never> { changed.eraseToAnyPublisher() }

    public init(value: Float, range: ClosedRange<Float>, defaultValue: Float, unit: Unit, step: Float? = nil) {
        precondition(range.lowerBound.isFinite && range.upperBound.isFinite && defaultValue.isFinite && range.contains(defaultValue))
        precondition(step == nil || (step!.isFinite && step! > 0))
        self.range = range
        self.defaultValue = Self.normalized(defaultValue, range: range, defaultValue: defaultValue, step: step)
        self.unit = unit
        self.step = step
        self.value = Self.normalized(value, range: range, defaultValue: self.defaultValue, step: step)
    }

    public final func setValue(_ value: Float) {
        let value = Self.normalized(value, range: range, defaultValue: defaultValue, step: step)
        guard self.value != value else { return }
        self.value = value
        changed.send()
    }

    public final func reset() { setValue(defaultValue) }

    private static func normalized(_ value: Float, range: ClosedRange<Float>, defaultValue: Float, step: Float?) -> Float {
        guard value.isFinite else { return defaultValue }
        let bounded = min(range.upperBound, max(range.lowerBound, value))
        guard let step else { return bounded }
        let lower = Double(range.lowerBound)
        let quantized = lower + ((Double(bounded) - lower) / Double(step)).rounded() * Double(step)
        return Float(min(Double(range.upperBound), max(lower, quantized)))
    }
}
