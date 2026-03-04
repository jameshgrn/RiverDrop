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

private func parseRemoteRipgrepLine(_ line: String) -> RemoteRipgrepResult? {
    guard let firstColon = line.firstIndex(of: ":") else { return nil }
    let filePath = String(line[line.startIndex..<firstColon])

    let afterFirst = line.index(after: firstColon)
    guard afterFirst < line.endIndex,
          let secondColon = line[afterFirst...].firstIndex(of: ":")
    else { return nil }

    let lineNumStr = String(line[afterFirst..<secondColon])
    guard let lineNum = Int(lineNumStr) else { return nil }

    let contentStart = line.index(after: secondColon)
    let content = contentStart < line.endIndex ? String(line[contentStart...]) : ""

    return RemoteRipgrepResult(
        filePath: filePath,
        lineNumber: lineNum,
        content: content.trimmingCharacters(in: .whitespaces)
    )
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
            let command = "rg --line-number --no-heading --color never --max-count 100 --max-columns 200 -- '\(escapedQuery)' '\(escapedDir)' 2>/dev/null"

            let output: String
            do {
                output = try await service.executeCommand(command)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "Remote search failed: \(error.localizedDescription)"
                return
            }

            guard !Task.isCancelled else { return }

            results = output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { parseRemoteRipgrepLine(String($0)) }
        }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }
}
