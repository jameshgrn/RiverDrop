import Foundation

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
        password: String,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        let destination = "\(username)@\(host):\(remotePath)"
        try await run(
            source: localPath,
            destination: destination,
            host: host,
            password: password,
            progressHandler: progressHandler
        )
    }

    func download(
        remotePath: String,
        localPath: String,
        host: String,
        username: String,
        password: String,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        let source = "\(username)@\(host):\(remotePath)"
        try await run(
            source: source,
            destination: localPath,
            host: host,
            password: password,
            progressHandler: progressHandler
        )
    }

    private func run(
        source: String,
        destination: String,
        host: String,
        password: String,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let rsyncPath = Self.rsyncPath else {
            throw RsyncError.notInstalled
        }

        let askpassScript = try createAskpassScript(password: password)
        defer { try? FileManager.default.removeItem(atPath: askpassScript) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rsyncPath)
        proc.arguments = [
            "-az",
            "--info=progress2",
            "--no-inc-recursive",
            "-e", "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null",
            source,
            destination,
        ]
        proc.environment = [
            "SSH_ASKPASS": askpassScript,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": ":0",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
        ]
        proc.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

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
                    if let match = progressRegex.firstMatch(in: line, range: range),
                       let percentRange = Range(match.range(at: 1), in: line),
                       let percent = Double(line[percentRange])
                    {
                        progressHandler(min(percent / 100.0, 1.0))
                    }
                }
            }

            proc.terminationHandler = { process in
                fileHandle.readabilityHandler = nil

                guard resumeGuard.setIfUnset() else { return }

                if process.terminationStatus == 0 {
                    progressHandler(1.0)
                    continuation.resume()
                } else if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(
                        throwing: RsyncError.processFailed(exitCode: process.terminationStatus)
                    )
                }
            }
        }
    }

    private func storeProcessIfNotCancelled(_ proc: Process) throws {
        try lock.withLock {
            if isCancelled {
                throw CancellationError()
            }
            process = proc
        }
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

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "rsync is not installed"
        case let .processFailed(exitCode):
            return "rsync exited with code \(exitCode)"
        }
    }
}
