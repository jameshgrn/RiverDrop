import Foundation

struct RemoteFileSearchResult: Identifiable {
    let id = UUID()
    let absolutePath: String   // full remote path from find output
    let relativePath: String   // display-only, relative to search root
    let filename: String
    let isDirectory: Bool

    var directoryPath: String {
        (absolutePath as NSString).deletingLastPathComponent
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

            let dirArgs = directories.map { $0.shellQuoted }.joined(separator: " ")
            let findCommand = "find \(dirArgs) -maxdepth 8 -iname \("*\(trimmed)*".shellQuoted) -not -path '*/.*' 2>/dev/null | head -300"

            do {
                let stream = try await service.executeCommandStream(findCommand)
                var lineBuffer = Data()
                var seen = Set<String>()

                for try await output in stream {
                    guard !Task.isCancelled else { return }
                    if case .stdout(var byteBuffer) = output,
                       let chunk = byteBuffer.readData(length: byteBuffer.readableBytes) {
                        lineBuffer.append(chunk)
                        while let newline = lineBuffer.firstIndex(of: 10) {
                            let lineData = lineBuffer[..<newline]
                            lineBuffer.removeSubrange(...newline)

                            let path = String(data: lineData, encoding: .utf8)?
                                .trimmingCharacters(in: .controlCharacters) ?? ""
                            guard !path.isEmpty, seen.insert(path).inserted else { continue }

                            let filename = (path as NSString).lastPathComponent
                            var relative = path
                            for dir in directories {
                                let prefix = dir.hasSuffix("/") ? dir : dir + "/"
                                if path.hasPrefix(prefix) {
                                    relative = String(path.dropFirst(prefix.count))
                                    break
                                }
                            }
                            results.append(RemoteFileSearchResult(
                                absolutePath: path,
                                relativePath: relative,
                                filename: filename,
                                isDirectory: false
                            ))
                        }
                    }
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

    deinit {
        searchTask?.cancel()
    }
}
