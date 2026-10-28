import Combine
import Foundation

@MainActor
public final class Parameter {
    public enum Unit: Sendable {
        case decibels, linearGain, balance, hertz, octaves, ratio
    }

    public let range: ClosedRange<Float>
    public let defaultValue: Float
    public let unit: Unit
    public private(set) var value: Float
    private let changed = PassthroughSubject<Void, Never>()
    public var changes: AnyPublisher<Void, Never> { changed.eraseToAnyPublisher() }

    public init(value: Float, range: ClosedRange<Float>, defaultValue: Float, unit: Unit) {
        precondition(defaultValue.isFinite && range.contains(defaultValue))
        self.range = range
        self.defaultValue = defaultValue
        self.unit = unit
        self.value = value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : defaultValue
    }

    public func setValue(_ value: Float) {
        let value = value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : defaultValue
        guard self.value != value else { return }
        self.value = value
        changed.send()
    }

    public func reset() { setValue(defaultValue) }
}
