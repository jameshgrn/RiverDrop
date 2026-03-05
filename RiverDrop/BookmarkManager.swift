import Foundation

struct SavedBookmark: Codable, Equatable {
    let label: String
    let path: String
}

enum BookmarkManager {
    static let defaultBookmarks: [(label: String, path: String)] = [
        ("Projects", "/Users/\(NSUserName())/projects"),
        ("Home", "/Users/\(NSUserName())"),
        ("Cluster Scratch", "/not_backed_up/\(NSUserName())"),
    ]

    static func load() -> [SavedBookmark] {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.savedBookmarks),
              let decoded = try? JSONDecoder().decode([SavedBookmark].self, from: data)
        else {
            return []
        }
        return decoded
    }

    static func save(_ bookmarks: [SavedBookmark]) {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKey.savedBookmarks)
    }

    static func add(label: String, path: String, to bookmarks: inout [SavedBookmark]) {
        guard !isBookmarked(path: path, in: bookmarks) else { return }
        bookmarks.append(SavedBookmark(label: label, path: path))
        save(bookmarks)
    }

    static func remove(_ bookmark: SavedBookmark, from bookmarks: inout [SavedBookmark]) {
        bookmarks.removeAll { $0 == bookmark }
        save(bookmarks)
    }

    static func isBookmarked(path: String, in savedBookmarks: [SavedBookmark]) -> Bool {
        defaultBookmarks.contains(where: { $0.path == path })
            || savedBookmarks.contains(where: { $0.path == path })
    }
}
