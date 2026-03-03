import Foundation

struct RemoteFileItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let filename: String
    let isDirectory: Bool
    let size: UInt64
    let modificationDate: Date?
}
