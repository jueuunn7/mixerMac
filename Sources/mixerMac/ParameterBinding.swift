import MixerCore
import SwiftUI

extension Parameter {
    var binding: Binding<Float> { Binding(get: { self.value }, set: { self.setValue($0) }) }
}
