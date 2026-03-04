import Citadel
import Foundation

struct RemoteRipgrepResult: Identifiable {
    let id = UUID()
    let filePath: String
    let lineNumber: Int
    let content: String

    var directoryPath: String {
        (filePath as NSString).deletingLastPathComponent
    }
}


@MainActor
final class RemoteRipgrepSearch: ObservableObject {
    @Published var results: [RemoteRipgrepResult] = []
    @Published var isSearching = false
    @Published var errorMessage: String?

    private var searchTask: Task<Void, Never>?

    func search(query: String, in directory: String, via service: SFTPService) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        cancel()
        results = []
        errorMessage = nil
        isSearching = true

        searchTask = Task {
            defer { isSearching = false }

            let escapedQuery = trimmed.replacingOccurrences(of: "'", with: "'\\''")
            let escapedDir = directory.replacingOccurrences(of: "'", with: "'\\''")
            let command = "rg --json --max-count 100 --max-columns 200 -- '\(escapedQuery)' '\(escapedDir)' 2>/dev/null"

            let output: String
            do {
                output = try await service.executeCommand(command)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "Remote search failed: \(error.localizedDescription)"
                return
            }

            guard !Task.isCancelled else { return }

            guard let data = output.data(using: .utf8) else { return }
            let parsed = parseRipgrepJSON(data)
            results = parsed.map { m in
                RemoteRipgrepResult(filePath: m.filePath, lineNumber: m.lineNumber, content: m.content)
            }
        }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }
}
