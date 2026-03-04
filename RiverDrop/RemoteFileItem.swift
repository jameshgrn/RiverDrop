import Foundation

struct RemoteFileItem: Identifiable, Hashable, Sendable {
    let filename: String
    let isDirectory: Bool
    let size: UInt64
    let modificationDate: Date?

    var id: String { filename }

    func hash(into hasher: inout Hasher) {
        hasher.combine(filename)
    }

    static func == (lhs: RemoteFileItem, rhs: RemoteFileItem) -> Bool {
        lhs.filename == rhs.filename
    }
}
