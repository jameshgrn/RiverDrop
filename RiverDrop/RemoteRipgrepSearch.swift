import Citadel
import Foundation
import NIOCore

extension String {
    /// Safely quotes a string for use in a POSIX shell command.
    var shellQuoted: String {
        if self.isEmpty { return "''" }
        return "'" + self.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

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
    @Published var ripgrepAvailable: Bool?

    private var searchTask: Task<Void, Never>?

    func checkRipgrepAvailable(via service: SFTPService) async {
        do {
            let output = try await service.executeCommand("command -v rg >/dev/null 2>&1; echo $?")
            let code = Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
            ripgrepAvailable = code == 0
        } catch {
            ripgrepAvailable = nil
        }
    }

    func search(query: String, in directory: String, via service: SFTPService) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        if ripgrepAvailable == false {
            errorMessage = "Ripgrep (rg) not found on server. Ask your system admin to install it, or run: conda install -c conda-forge ripgrep"
            return
        }

        cancel()
        results = []
        errorMessage = nil
        isSearching = true

        searchTask = Task {
            defer { isSearching = false }

            let escapedQuery = trimmed.shellQuoted
            let escapedDir = directory.shellQuoted

            // Instead of wrapping in an echo $? subshell and buffering everything,
            // we use the streaming API. If rg returns 1 (no matches), Citadel will throw an error,
            // which we can safely ignore.
            let rgCommand = "rg --json --max-count \(maxCount) --max-columns \(maxColumns) -- \(escapedQuery) \(escapedDir) 2>/dev/null"

            do {
                let stream = try await service.executeCommandStream(rgCommand)
                let decoder = JSONDecoder()
                var lineBuffer = Data()

                for try await output in stream {
                    guard !Task.isCancelled else { return }
                    switch output {
                    case .stdout(var byteBuffer):
                        if let data = byteBuffer.readData(length: byteBuffer.readableBytes) {
                            lineBuffer.append(data)
                            while let index = lineBuffer.firstIndex(of: 10) { // \n
                                let lineData = lineBuffer[..<index]
                                lineBuffer.removeSubrange(...index)
                                
                                if let message = try? decoder.decode(RipgrepJSONMessage.self, from: lineData),
                                   message.type == "match",
                                   let data = message.data,
                                   let path = data.path?.text,
                                   let lineNumber = data.line_number,
                                   let content = data.lines?.text {
                                    
                                    let result = RemoteRipgrepResult(
                                        filePath: path,
                                        lineNumber: lineNumber,
                                        content: content.trimmingCharacters(in: .whitespacesAndNewlines)
                                    )
                                    // Append incrementally to provide a streaming UI update
                                    self.results.append(result)
                                }
                            }
                        }
                    case .stderr:
                        // Suppressed via 2>/dev/null, but ignore if any leaks through
                        break
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                
                // Exit code 1 means no matches found, which throws in Citadel but is not an application error.
                let errStr = String(describing: error)
                if errStr.contains("exitStatus(1)") || errStr.contains("exit status 1") || errStr.contains("1") {
                    // It's just no matches.
                } else if errStr.contains("127") {
                    self.ripgrepAvailable = false
                    self.errorMessage = "Ripgrep (rg) not found on server."
                } else {
                    self.errorMessage = "Remote search failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }
}
