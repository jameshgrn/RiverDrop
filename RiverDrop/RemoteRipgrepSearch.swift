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
    @Published var maxCount: Int = 100
    @Published var maxColumns: Int = 200

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

            // Use --json for structured parsing; suppress stderr for clean output;
            // append exit code so we can distinguish no-matches (1) from errors (2+).
            let rgCommand = "rg --json --max-count \(maxCount) --max-columns \(maxColumns) -- '\(escapedQuery)' '\(escapedDir)' 2>/dev/null"
            let command = "(\(rgCommand)); echo $?"

            let output: String
            do {
                output = try await service.executeCommand(command)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "Remote search failed: \(error.localizedDescription)"
                return
            }

            guard !Task.isCancelled else { return }

            let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

            guard let lastLine = lines.last,
                  let exitCode = Int(lastLine.trimmingCharacters(in: .whitespaces)) else {
                errorMessage = "Remote search failed: Could not determine search exit status"
                return
            }

            let resultLines = lines.dropLast()

            if exitCode == 0 {
                let jsonOutput = resultLines.joined(separator: "\n")
                guard let data = jsonOutput.data(using: .utf8) else { return }
                let parsed = parseRipgrepJSON(data)
                results = parsed.map { m in
                    RemoteRipgrepResult(filePath: m.filePath, lineNumber: m.lineNumber, content: m.content)
                }
            } else if exitCode == 1 {
                // Exit code 1 means no matches found, which is not an error.
                results = []
            } else {
                // Exit code 2+ (e.g., 127 for rg not installed) are real errors.
                errorMessage = "Remote search failed with exit code \(exitCode)"
            }
        }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }
}
