import Foundation

struct LocalFileItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let filename: String
    let isDirectory: Bool
    let size: UInt64
    let modificationDate: Date?
    let url: URL

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    static func == (lhs: LocalFileItem, rhs: LocalFileItem) -> Bool {
        lhs.url == rhs.url
    }
}
