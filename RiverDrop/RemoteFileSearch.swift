import Foundation

struct RemoteFileSearchResult: Identifiable {
    let id = UUID()
    let relativePath: String
    let filename: String
    let isDirectory: Bool

    var directoryPath: String {
        (relativePath as NSString).deletingLastPathComponent
    }
}

@MainActor
final class RemoteFileSearch: ObservableObject {
    @Published var results: [RemoteFileSearchResult] = []
    @Published var isSearching = false
    @Published var errorMessage: String?

    private var searchTask: Task<Void, Never>?

    func search(query: String, in directories: [String], via service: SFTPService) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        cancel()
        results = []
        errorMessage = nil
        isSearching = true

        searchTask = Task {
            defer { isSearching = false }

            let escapedPattern = "*\(trimmed)*"

            // Build a single find command across all directories.
            // Use -maxdepth 8 to avoid runaway traversal, -iname for case-insensitive.
            let dirArgs = directories
                .map { $0.shellQuoted }
                .joined(separator: " ")
            let findCommand = "find \(dirArgs) -maxdepth 8 -iname \(escapedPattern.shellQuoted) -not -path '*/.*' 2>/dev/null | head -200"

            do {
                let output = try await service.executeCommand(findCommand, mergeStreams: false)
                guard !Task.isCancelled else { return }

                let lines = output.split(whereSeparator: \.isNewline)
                var seen = Set<String>()
                for line in lines {
                    let path = String(line)
                    guard !path.isEmpty, seen.insert(path).inserted else { continue }

                    let filename = (path as NSString).lastPathComponent
                    let isDir = filename.contains(".") ? false : true // heuristic

                    // Build relative path from the first matching search root
                    var relative = path
                    for dir in directories {
                        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
                        if path.hasPrefix(prefix) {
                            relative = String(path.dropFirst(prefix.count))
                            break
                        }
                    }

                    results.append(RemoteFileSearchResult(
                        relativePath: relative,
                        filename: filename,
                        isDirectory: isDir
                    ))
                }

                if results.isEmpty {
                    errorMessage = "No files matching \"\(trimmed)\""
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "Search failed: \(error.localizedDescription)"
            }
        }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }
}
