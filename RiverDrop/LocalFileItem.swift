import Foundation

struct LocalFileItem: Identifiable, Hashable, Sendable {
    let filename: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: UInt64
    let modificationDate: Date?
    let url: URL
    let resolvedURL: URL

    var id: URL { url }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    static func == (lhs: LocalFileItem, rhs: LocalFileItem) -> Bool {
        lhs.url == rhs.url
    }
}
