import Foundation

struct RipgrepResult: Identifiable {
    let id = UUID()
    let filePath: String
    let lineNumber: Int
    let content: String

    var directoryURL: URL {
        URL(fileURLWithPath: filePath).deletingLastPathComponent()
    }
}

private func parseRipgrepLine(_ line: String) -> RipgrepResult? {
    // Format: filepath:linenum:content
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

    return RipgrepResult(filePath: filePath, lineNumber: lineNum, content: content.trimmingCharacters(in: .whitespaces))
}

@MainActor
final class RipgrepSearch: ObservableObject {
    @Published var results: [RipgrepResult] = []
    @Published var isSearching = false
    @Published var errorMessage: String?

    private var process: Process?

    static var rgPath: String? {
        for path in ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    static var isAvailable: Bool { rgPath != nil }

    func search(query: String, in directory: String) {
        guard let rgPath = Self.rgPath else {
            errorMessage = "ripgrep (rg) is not installed"
            return
        }

        cancel()
        results = []
        errorMessage = nil
        isSearching = true

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rgPath)
        proc.arguments = [
            "--line-number",
            "--no-heading",
            "--color", "never",
            "--max-count", "100",
            "--max-columns", "200",
            query,
            directory,
        ]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        process = proc

        let fileHandle = pipe.fileHandleForReading

        proc.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.isSearching = false
                self?.process = nil
                if process.terminationStatus != 0 && process.terminationStatus != 1 {
                    self?.errorMessage = "rg exited with code \(process.terminationStatus)"
                }
            }
        }

        do {
            try proc.run()
        } catch {
            isSearching = false
            process = nil
            errorMessage = "Failed to start rg: \(error.localizedDescription)"
            return
        }

        // Read output on a background queue
        Task.detached { [weak self] in
            let data = fileHandle.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return }

            let parsed = output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { parseRipgrepLine(String($0)) }

            await MainActor.run { [weak self] in
                self?.results = parsed
            }
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
        isSearching = false
    }
}
