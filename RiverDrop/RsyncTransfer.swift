import Foundation

enum RsyncAuth: Sendable {
    case password(String)
    case sshKey(path: String, passphrase: String?)
}

final class RsyncTransfer: @unchecked Sendable {
    private var process: Process?
    private let lock = NSLock()
    private var isCancelled = false

    static var rsyncPath: String? {
        for path in ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync", "/usr/bin/rsync"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    static var isAvailable: Bool { rsyncPath != nil }

    func cancel() {
        let proc = lock.withLock {
            isCancelled = true
            return process
        }
        proc?.terminate()
    }

    func upload(
        localPath: String,
        remotePath: String,
        host: String,
        username: String,
        auth: RsyncAuth,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        let destination = "\(username)@\(host):\(remotePath)"
        try await run(
            source: localPath,
            destination: destination,
            host: host,
            auth: auth,
            progressHandler: progressHandler
        )
    }

    func download(
        remotePath: String,
        localPath: String,
        host: String,
        username: String,
        auth: RsyncAuth,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        let source = "\(username)@\(host):\(remotePath)"
        try await run(
            source: source,
            destination: localPath,
            host: host,
            auth: auth,
            progressHandler: progressHandler
        )
    }

    func syncDownload(
        remotePath: String,
        localPath: String,
        host: String,
        username: String,
        auth: RsyncAuth,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        let sourcePath = remotePath.hasSuffix("/") ? remotePath : remotePath + "/"
        let source = "\(username)@\(host):\(sourcePath)"
        let dest = localPath.hasSuffix("/") ? localPath : localPath + "/"
        try await runSync(
            source: source,
            destination: dest,
            host: host,
            auth: auth,
            progressHandler: progressHandler
        )
    }

    func syncUpload(
        localPath: String,
        remotePath: String,
        host: String,
        username: String,
        auth: RsyncAuth,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        let sourcePath = localPath.hasSuffix("/") ? localPath : localPath + "/"
        let dest = remotePath.hasSuffix("/") ? remotePath : remotePath + "/"
        let destination = "\(username)@\(host):\(dest)"
        try await runSync(
            source: sourcePath,
            destination: destination,
            host: host,
            auth: auth,
            progressHandler: progressHandler
        )
    }

    private func run(
        source: String,
        destination: String,
        host: String,
        auth: RsyncAuth,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let rsyncPath = Self.rsyncPath else {
            throw RsyncError.notInstalled
        }

        var tempFiles: [String] = []
        defer { for path in tempFiles { try? FileManager.default.removeItem(atPath: path) } }

        let knownHostsPath = try createKnownHostsFile(for: host)
        tempFiles.append(knownHostsPath)

        var sshCommand = "ssh -T -o Compression=no -o IPQoS=throughput -o StrictHostKeyChecking=yes -o UserKnownHostsFile=\(shellQuote(knownHostsPath))"
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
        ]

        switch auth {
        case let .password(password):
            let askpassScript = try createAskpassScript(password: password)
            tempFiles.append(askpassScript)
            environment["SSH_ASKPASS"] = askpassScript
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = ":0"
        case let .sshKey(keyPath, passphrase):
            let tempKeyPath = try copySSHKeyToTemp(keyPath)
            tempFiles.append(tempKeyPath)
            sshCommand += " -i \(shellQuote(tempKeyPath)) -o IdentitiesOnly=yes"
            if let passphrase {
                let askpassScript = try createAskpassScript(password: passphrase)
                tempFiles.append(askpassScript)
                environment["SSH_ASKPASS"] = askpassScript
                environment["SSH_ASKPASS_REQUIRE"] = "force"
                environment["DISPLAY"] = ":0"
            }
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rsyncPath)
        proc.arguments = [
            "-a",
            "--whole-file",
            "--inplace",
            "--partial",
            "--progress",
            "-e", sshCommand,
            source,
            destination,
        ]
        proc.environment = environment
        proc.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        try storeProcessIfNotCancelled(proc)
        try proc.run()

        let fileHandle = pipe.fileHandleForReading
        let progressRegex = try NSRegularExpression(pattern: #"(\d+)%"#)
        let resumeGuard = AtomicFlag()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            fileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }

                if let line = String(data: data, encoding: .utf8) {
                    let range = NSRange(line.startIndex..., in: line)
                    if let match = progressRegex.matches(in: line, range: range).last,
                       let percentRange = Range(match.range(at: 1), in: line),
                       let percent = Double(line[percentRange])
                    {
                        progressHandler(min(percent / 100.0, 1.0))
                    }
                }
            }

            proc.terminationHandler = { [weak self] process in
                fileHandle.readabilityHandler = nil
                self?.clearProcess()

                guard resumeGuard.setIfUnset() else { return }

                if process.terminationStatus == 0 {
                    progressHandler(1.0)
                    continuation.resume()
                } else if self?.isTransferCancelled() == true || process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(
                        throwing: RsyncError.processFailed(exitCode: process.terminationStatus)
                    )
                }
            }
        }
    }

    private func runSync(
        source: String,
        destination: String,
        host: String,
        auth: RsyncAuth,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let rsyncPath = Self.rsyncPath else {
            throw RsyncError.notInstalled
        }

        var tempFiles: [String] = []
        defer { for path in tempFiles { try? FileManager.default.removeItem(atPath: path) } }

        let knownHostsPath = try createKnownHostsFile(for: host)
        tempFiles.append(knownHostsPath)

        var sshCommand = "ssh -T -o Compression=no -o IPQoS=throughput -o StrictHostKeyChecking=yes -o UserKnownHostsFile=\(shellQuote(knownHostsPath))"
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
        ]

        switch auth {
        case let .password(password):
            let askpassScript = try createAskpassScript(password: password)
            tempFiles.append(askpassScript)
            environment["SSH_ASKPASS"] = askpassScript
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = ":0"
        case let .sshKey(keyPath, passphrase):
            let tempKeyPath = try copySSHKeyToTemp(keyPath)
            tempFiles.append(tempKeyPath)
            sshCommand += " -i \(shellQuote(tempKeyPath)) -o IdentitiesOnly=yes"
            if let passphrase {
                let askpassScript = try createAskpassScript(password: passphrase)
                tempFiles.append(askpassScript)
                environment["SSH_ASKPASS"] = askpassScript
                environment["SSH_ASKPASS_REQUIRE"] = "force"
                environment["DISPLAY"] = ":0"
            }
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rsyncPath)
        proc.arguments = [
            "-a",
            "--delete",
            "--partial",
            "--progress",
            "-e", sshCommand,
            source,
            destination,
        ]
        proc.environment = environment
        proc.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        try storeProcessIfNotCancelled(proc)
        try proc.run()

        let fileHandle = pipe.fileHandleForReading
        let progressRegex = try NSRegularExpression(pattern: #"(\d+)%"#)
        let resumeGuard = AtomicFlag()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            fileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }

                if let line = String(data: data, encoding: .utf8) {
                    let range = NSRange(line.startIndex..., in: line)
                    if let match = progressRegex.matches(in: line, range: range).last,
                       let percentRange = Range(match.range(at: 1), in: line),
                       let percent = Double(line[percentRange])
                    {
                        progressHandler(min(percent / 100.0, 1.0))
                    }
                }
            }

            proc.terminationHandler = { [weak self] process in
                fileHandle.readabilityHandler = nil
                self?.clearProcess()

                guard resumeGuard.setIfUnset() else { return }

                if process.terminationStatus == 0 {
                    progressHandler(1.0)
                    continuation.resume()
                } else if self?.isTransferCancelled() == true || process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(
                        throwing: RsyncError.processFailed(exitCode: process.terminationStatus)
                    )
                }
            }
        }
    }

    // MARK: - Dry Run

    func dryRunDownload(
        remotePath: String,
        localPath: String,
        host: String,
        username: String,
        auth: RsyncAuth
    ) async throws -> DryRunResult {
        let sourcePath = remotePath.hasSuffix("/") ? remotePath : remotePath + "/"
        let source = "\(username)@\(host):\(sourcePath)"
        let dest = localPath.hasSuffix("/") ? localPath : localPath + "/"
        return try await runDryRun(source: source, destination: dest, host: host, auth: auth)
    }

    func dryRunUpload(
        localPath: String,
        remotePath: String,
        host: String,
        username: String,
        auth: RsyncAuth
    ) async throws -> DryRunResult {
        let sourcePath = localPath.hasSuffix("/") ? localPath : localPath + "/"
        let destination = "\(username)@\(host):\(remotePath)"
        return try await runDryRun(source: sourcePath, destination: destination, host: host, auth: auth)
    }

    private func runDryRun(
        source: String,
        destination: String,
        host: String,
        auth: RsyncAuth
    ) async throws -> DryRunResult {
        guard let rsyncPath = Self.rsyncPath else {
            throw RsyncError.notInstalled
        }

        var tempFiles: [String] = []
        defer { for path in tempFiles { try? FileManager.default.removeItem(atPath: path) } }

        let knownHostsPath = try createKnownHostsFile(for: host)
        tempFiles.append(knownHostsPath)

        var sshCommand = "ssh -T -o Compression=no -o StrictHostKeyChecking=yes -o UserKnownHostsFile=\(shellQuote(knownHostsPath))"
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
        ]

        switch auth {
        case let .password(password):
            let askpassScript = try createAskpassScript(password: password)
            tempFiles.append(askpassScript)
            environment["SSH_ASKPASS"] = askpassScript
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = ":0"
        case let .sshKey(keyPath, passphrase):
            let tempKeyPath = try copySSHKeyToTemp(keyPath)
            tempFiles.append(tempKeyPath)
            sshCommand += " -i \(shellQuote(tempKeyPath)) -o IdentitiesOnly=yes"
            if let passphrase {
                let askpassScript = try createAskpassScript(password: passphrase)
                tempFiles.append(askpassScript)
                environment["SSH_ASKPASS"] = askpassScript
                environment["SSH_ASKPASS_REQUIRE"] = "force"
                environment["DISPLAY"] = ":0"
            }
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rsyncPath)
        proc.arguments = [
            "-a",
            "--dry-run",
            "--delete",
            "--out-format=%i %l %n",
            "-e", sshCommand,
            source,
            destination,
        ]
        proc.environment = environment
        proc.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try storeProcessIfNotCancelled(proc)
        try proc.run()

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        let stdoutData = await Task.detached { stdoutHandle.readDataToEndOfFile() }.value
        let stderrData = await Task.detached { stderrHandle.readDataToEndOfFile() }.value
        await Task.detached { proc.waitUntilExit() }.value
        clearProcess()

        if isTransferCancelled() {
            throw CancellationError()
        }

        if proc.terminationStatus != 0 {
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            throw RsyncError.dryRunFailed(exitCode: proc.terminationStatus, stderr: stderr)
        }

        let output = String(data: stdoutData, encoding: .utf8) ?? ""
        return parseDryRunOutput(output)
    }

    private func storeProcessIfNotCancelled(_ proc: Process) throws {
        try lock.withLock {
            if isCancelled {
                throw CancellationError()
            }
            process = proc
        }
    }

    private func clearProcess() {
        lock.withLock {
            process = nil
        }
    }

    private func isTransferCancelled() -> Bool {
        lock.withLock { isCancelled }
    }

    private func createAskpassScript(password: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
        let scriptPath = dir.appendingPathComponent("riverdrop_askpass_\(UUID().uuidString).sh").path

        let escaped = password.replacingOccurrences(of: "'", with: "'\\''")
        let content = "#!/bin/sh\necho '\(escaped)'\n"

        FileManager.default.createFile(atPath: scriptPath, contents: content.data(using: .utf8))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptPath
        )
        return scriptPath
    }

    private func createKnownHostsFile(for host: String) throws -> String {
        guard let openSSHKey = loadKnownHostKey(for: host) else {
            throw RsyncError.hostKeyMissing(host: host)
        }

        let dir = FileManager.default.temporaryDirectory
        let filePath = dir.appendingPathComponent("riverdrop_knownhosts_\(UUID().uuidString)").path
        let content = "\(host) \(openSSHKey)\n"

        guard FileManager.default.createFile(
            atPath: filePath,
            contents: content.data(using: .utf8)
        ) else {
            throw RsyncError.knownHostsWriteFailed(path: filePath)
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: filePath
        )
        return filePath
    }

    private func loadKnownHostKey(for host: String) -> String? {
        HostKeyKeychainHelper.load(for: host)
    }

    /// Copy an SSH key to the app's temp directory so the unsandboxed rsync
    /// subprocess can read it. Returns the temp file path (caller must delete).
    private func copySSHKeyToTemp(_ keyPath: String) throws -> String {
        let src = URL(fileURLWithPath: keyPath)
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("riverdrop_sshkey_\(UUID().uuidString)")
        try FileManager.default.copyItem(at: src, to: dst)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: dst.path
        )
        return dst.path
    }

    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Thread-safe one-shot flag for ensuring a continuation is resumed exactly once.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    /// Returns `true` if this call set the flag (first caller wins). Returns `false` if already set.
    func setIfUnset() -> Bool {
        lock.withLock {
            if isSet { return false }
            isSet = true
            return true
        }
    }
}

enum RsyncError: LocalizedError {
    case notInstalled
    case processFailed(exitCode: Int32)
    case hostKeyMissing(host: String)
    case knownHostsWriteFailed(path: String)
    case dryRunFailed(exitCode: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "rsync is not installed"
        case let .processFailed(exitCode):
            return "rsync exited with code \(exitCode)"
        case let .hostKeyMissing(host):
            return "No trusted host key found for \(host). Connect via SFTP first to trust and store the server key."
        case let .knownHostsWriteFailed(path):
            return "Could not write temporary known_hosts file at \(path)"
        case let .dryRunFailed(exitCode, stderr):
            return "rsync dry-run exited with code \(exitCode): \(stderr)"
        }
    }
}

// MARK: - Dry Run Model

struct DryRunFileEntry: Identifiable, Sendable {
    let id = UUID()
    let path: String
    let size: Int64
    let change: ChangeType

    enum ChangeType: Sendable {
        case added, modified, deleted
    }
}

struct DryRunResult: Sendable {
    let added: [DryRunFileEntry]
    let modified: [DryRunFileEntry]
    let deleted: [DryRunFileEntry]

    var totalFiles: Int { added.count + modified.count + deleted.count }
    var isEmpty: Bool { totalFiles == 0 }
    var totalBytes: Int64 { (added + modified).reduce(0) { $0 + $1.size } }
}

// MARK: - Dry Run Parsing (free functions — not in @MainActor)

func parseDryRunOutput(_ output: String) -> DryRunResult {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
    let entries = lines.compactMap { parseDryRunLine(String($0)) }
    return DryRunResult(
        added: entries.filter { $0.change == .added },
        modified: entries.filter { $0.change == .modified },
        deleted: entries.filter { $0.change == .deleted }
    )
}

func parseDryRunLine(_ line: String) -> DryRunFileEntry? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    // Delete lines: "*deleting   filename"
    if trimmed.hasPrefix("*deleting") {
        let filename = String(trimmed.dropFirst("*deleting".count))
            .trimmingCharacters(in: .whitespaces)
        guard !filename.isEmpty else { return nil }
        return DryRunFileEntry(path: filename, size: 0, change: .deleted)
    }

    // Itemize format: "YXcstpoguax <size> <filename>" (11-char prefix from --out-format=%i %l %n)
    guard trimmed.count > 13 else { return nil }

    let itemize = String(trimmed.prefix(11))
    let fileType = itemize[itemize.index(after: itemize.startIndex)]

    let rest = String(trimmed.dropFirst(11)).trimmingCharacters(in: .whitespaces)
    let parts = rest.split(separator: " ", maxSplits: 1)
    guard parts.count == 2 else { return nil }

    if fileType == "d" {
        let filename = String(parts[1])
        let change: DryRunFileEntry.ChangeType = itemize.contains("+++++++++") ? .added : .modified
        return DryRunFileEntry(path: filename, size: 0, change: change)
    }

    guard let size = Int64(parts[0]) else { return nil }
    let filename = String(parts[1])

    let change: DryRunFileEntry.ChangeType = itemize.contains("+++++++++") ? .added : .modified
    return DryRunFileEntry(path: filename, size: size, change: change)
}
