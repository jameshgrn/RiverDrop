import Foundation

struct LocalFileSearchResult: Identifiable {
    let id = UUID()
    let url: URL
    let relativePath: String

    var filename: String { url.lastPathComponent }
    var directoryURL: URL { url.deletingLastPathComponent() }
}

@MainActor
final class LocalFileSearch: ObservableObject {
    @Published var results: [LocalFileSearchResult] = []
    @Published var isSearching = false

    private var process: Process?
    private var searchRoots: [URL] = []

    func search(query: String, in directories: [URL]) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        cancel()
        results = []
        isSearching = true
        searchRoots = directories

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/find")

        var args: [String] = []
        for dir in directories { args.append(dir.path) }
        args += ["-maxdepth", "6", "-iname", "*\(trimmed)*", "-not", "-path", "*/.*"]

        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        process = proc

        let roots = directories
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isSearching = false
                self?.process = nil
            }
        }

        do {
            try proc.run()
        } catch {
            isSearching = false
            process = nil
            return
        }

        let fileHandle = pipe.fileHandleForReading
        Task.detached { [weak self] in
            do {
                for try await line in fileHandle.bytes.lines {
                    guard !line.isEmpty else { continue }
                    let url = URL(fileURLWithPath: line)
                    var relative = line
                    for root in roots {
                        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
                        if line.hasPrefix(prefix) {
                            relative = String(line.dropFirst(prefix.count))
                            break
                        }
                    }
                    let result = LocalFileSearchResult(url: url, relativePath: relative)
                    await MainActor.run { [weak self] in
                        self?.results.append(result)
                    }
                }
            } catch {}
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
        isSearching = false
    }
}
