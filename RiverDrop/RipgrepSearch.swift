import Foundation

struct RipgrepResult: Identifiable {
    let id = UUID()
    let filePath: String
    let lineNumber: Int
    let content: String

    var directoryURL: URL {
        URL(fileURLWithPath: filePath).deletingLastPathComponent()
    }

    var fileName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

struct RipgrepJSONMessage: Codable {
    let type: String
    let data: RipgrepJSONData?
}

struct RipgrepJSONData: Codable {
    struct Path: Codable {
        let text: String
    }
    struct Lines: Codable {
        let text: String
    }
    let path: Path?
    let line_number: Int?
    let lines: Lines?
}

func parseRipgrepJSON(_ data: Data) -> [RipgrepResult] {
    let decoder = JSONDecoder()
    guard let output = String(data: data, encoding: .utf8) else { return [] }

    let lines = output.split(whereSeparator: { $0.isNewline })
    return lines.compactMap { line in
        guard let lineData = line.data(using: .utf8),
              let message = try? decoder.decode(RipgrepJSONMessage.self, from: lineData),
              message.type == "match",
              let data = message.data,
              let path = data.path?.text,
              let lineNumber = data.line_number,
              let content = data.lines?.text else {
            return nil
        }
        return RipgrepResult(
            filePath: path,
            lineNumber: lineNumber,
            content: content.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

@MainActor
final class RipgrepSearch: ObservableObject {
    @Published var results: [RipgrepResult] = []
    @Published var isSearching = false
    @Published var errorMessage: String?
    @Published var searchCompleted = false
    @Published var resultCount: Int = 0
    @Published var searchDirectory: String = ""

    private var process: Process?
    private var accessedURL: URL?
    private var currentSearchToken: UUID?

    static var rgPath: String? {
        for path in ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    static var isAvailable: Bool { rgPath != nil }

    /// Search file contents using ripgrep.
    /// - Parameters:
    ///   - query: The search pattern.
    ///   - directory: Directory URL to search in.
    ///   - recursive: When false, only searches files in the top-level directory.
    ///   - fileTypes: File extensions to restrict search to (e.g. ["py", "swift"]).
    ///   - securityScopedURL: If provided, security-scoped access is started before
    ///     launching `rg` and stopped after it exits. Pass the URL obtained from a
    ///     security-scoped bookmark so the subprocess inherits sandbox access.
    func search(
        query: String,
        in directory: URL,
        recursive: Bool = true,
        fileTypes: [String] = [],
        securityScopedURL: URL? = nil
    ) {
        guard let rgPath = Self.rgPath else {
            errorMessage = "ripgrep (rg) is not installed"
            return
        }

        cancel()
        
        let token = UUID()
        currentSearchToken = token
        
        results = []
        errorMessage = nil
        searchCompleted = false
        resultCount = 0
        searchDirectory = directory.path
        isSearching = true

        // Start security-scoped access so the child process inherits sandbox tokens.
        if let scopedURL = securityScopedURL {
            if scopedURL.startAccessingSecurityScopedResource() {
                accessedURL = scopedURL
            }
        }

        var args: [String] = [
            "--json",
            "--max-count", "100",
            "--max-columns", "200",
        ]

        if !recursive {
            args.append(contentsOf: ["--max-depth", "1"])
        }

        for ext in fileTypes {
            let cleaned = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
            if !cleaned.isEmpty {
                args.append(contentsOf: ["--glob", "*.\(cleaned)"])
            }
        }

        args.append(query)
        args.append(directory.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rgPath)
        proc.arguments = args

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        process = proc

        let fileHandle = pipe.fileHandleForReading

        proc.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self = self, self.currentSearchToken == token else { return }
                self.isSearching = false
                self.searchCompleted = true
                self.process = nil
                if process.terminationStatus != 0 && process.terminationStatus != 1 {
                    self.errorMessage = "rg exited with code \(process.terminationStatus)"
                }
            }
        }

        do {
            try proc.run()
        } catch {
            if currentSearchToken == token {
                isSearching = false
                searchCompleted = true
                process = nil
                stopSecurityScopedAccess()
                errorMessage = "Failed to start rg: \(error.localizedDescription)"
            }
            return
        }

        // Read output on a background thread; stop security-scoped access after drain.
        Task.detached { [weak self] in
            let data = fileHandle.readDataToEndOfFile()

            await MainActor.run { [weak self] in
                guard let self = self, self.currentSearchToken == token else { return }
                self.stopSecurityScopedAccess()
            }

            let parsed = parseRipgrepJSON(data)

            await MainActor.run { [weak self] in
                guard let self = self, self.currentSearchToken == token else { return }
                self.results = parsed
                self.resultCount = parsed.count
            }
        }
    }

    func cancel() {
        currentSearchToken = nil
        process?.terminate()
        process = nil
        isSearching = false
        stopSecurityScopedAccess()
    }

    /// Compute a display path relative to the search directory.
    func relativePath(for result: RipgrepResult) -> String {
        let base = searchDirectory.hasSuffix("/") ? searchDirectory : searchDirectory + "/"
        if result.filePath.hasPrefix(base) {
            return String(result.filePath.dropFirst(base.count))
        }
        return result.filePath
    }

    private func stopSecurityScopedAccess() {
        if let url = accessedURL {
            url.stopAccessingSecurityScopedResource()
            accessedURL = nil
        }
    }
}
