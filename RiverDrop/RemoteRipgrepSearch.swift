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
            
            // Remove 2>/dev/null to capture errors, and use echo $? to capture the exit code.
            // Wrapping in (...) ensures we get the exit code of rg specifically.
            let rgCommand = "rg --line-number --no-heading --color never --max-count 100 --max-columns 200 -- '\(escapedQuery)' '\(escapedDir)'"
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
                results = resultLines.compactMap { line in
                    guard let m = parseRipgrepFields(line) else { return nil }
                    return RemoteRipgrepResult(filePath: m.filePath, lineNumber: m.lineNumber, content: m.content)
                }
            } else if exitCode == 1 {
                // Exit code 1 means no matches found, which is not an error.
                results = []
            } else {
                // Exit code 2 or others (like 127) are errors.
                let errorOutput = resultLines.joined(separator: "\n").trimmingCharacters(in: .whitespaces)
                errorMessage = errorOutput.isEmpty ? "Remote search failed with exit code \(exitCode)" : errorOutput
            }
        }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }
}
