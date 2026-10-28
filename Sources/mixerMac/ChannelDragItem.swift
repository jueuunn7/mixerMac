import CoreTransferable
import UniformTypeIdentifiers

struct ChannelDragItem: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mixerChannel)
    }
}

extension UTType {
    static let mixerChannel = UTType(exportedAs: "local.mixermac.console-channel")
}
