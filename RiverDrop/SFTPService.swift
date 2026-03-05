import Citadel
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOSSH

@MainActor
@Observable
final class SFTPService {
    var isConnected = false
    var connectedUsername = ""
    var connectedHost = ""
    var homePath = ""
    var currentPath = ""
    var files: [RemoteFileItem] = []
    var errorMessage: String?
    private(set) var connectedAuthConfig: SSHAuthConfig?
    private var connectedProxyJump: String?
    private var connectedPort = 22

    var connectionMethodLabel: String {
        isConnected ? "SFTP" : "Disconnected"
    }

    var authenticationMethodLabel: String {
        switch connectedAuthConfig {
        case .password:
            return "Password"
        case let .sshKey(keyPath, _):
            return "SSH Key (\((keyPath as NSString).lastPathComponent))"
        case nil:
            return "None"
        }
    }

    private let session = SFTPSession()
    private var reconnectTask: Task<Void, Never>?

    func connect(host: String, username: String, password: String) async {
        await connect(host: host, username: username, auth: .password(password))
    }

    func connect(host: String, username: String, keyPath: String, passphrase: String?) async {
        await connect(host: host, username: username, auth: .sshKey(keyPath: keyPath, passphrase: passphrase))
    }

    func connect(server: ServerEntry, auth: SSHAuthConfig) async {
        if server.proxyJump != nil {
            await connectViaProxy(server: server, auth: auth)
        } else {
            await connect(host: server.host, username: server.user, auth: auth)
        }
    }

    private func connect(host: String, username: String, auth: SSHAuthConfig) async {
        // Run kinit/klog before connection for HPC environments
        _ = await runKinitKlog()

        let knownHostKey = HostKeyStore.load(for: host)
        let validator = TOFUHostKeyValidator(expectedOpenSSHKey: knownHostKey)

        do {
            let resolvedHome = try await session.connect(
                host: host,
                username: username,
                auth: auth,
                hostKeyValidator: .custom(validator)
            )

            if knownHostKey == nil, let acceptedKey = validator.acceptedOpenSSHKey {
                HostKeyStore.save(acceptedKey, for: host)
            }

            connectedUsername = username
            connectedHost = host
            connectedAuthConfig = auth
            homePath = resolvedHome
            currentPath = resolvedHome
            isConnected = true
            errorMessage = nil
            await listDirectory()
            startReconnectionTimer()
        } catch {
            isConnected = false
            connectedUsername = ""
            connectedHost = ""
            connectedAuthConfig = nil
            homePath = ""
            currentPath = ""
            files = []
            errorMessage = formatError(
                operation: "connect",
                input: "\(username)@\(host)",
                error: error,
                suggestedFix: "verify hostname, credentials, and the server host key fingerprint"
            )
        }
    }

    private func connectViaProxy(server: ServerEntry, auth: SSHAuthConfig) async {
        _ = await runKinitKlog()

        let knownHostKey = HostKeyStore.load(for: server.host)
        let validator = TOFUHostKeyValidator(expectedOpenSSHKey: knownHostKey)

        do {
            let resolvedHome = try await session.connectViaProxy(
                host: server.host,
                port: server.port,
                proxyJump: server.proxyJump!,
                username: server.user,
                auth: auth,
                hostKeyValidator: .custom(validator)
            )

            if knownHostKey == nil, let acceptedKey = validator.acceptedOpenSSHKey {
                HostKeyStore.save(acceptedKey, for: server.host)
            }

            connectedUsername = server.user
            connectedHost = server.host
            connectedAuthConfig = auth
            connectedProxyJump = server.proxyJump
            connectedPort = server.port
            homePath = resolvedHome
            currentPath = resolvedHome
            isConnected = true
            errorMessage = nil
            await listDirectory()
            startReconnectionTimer()
        } catch {
            isConnected = false
            connectedUsername = ""
            connectedHost = ""
            connectedAuthConfig = nil
            connectedProxyJump = nil
            connectedPort = 22
            homePath = ""
            currentPath = ""
            files = []
            errorMessage = formatError(
                operation: "connect via proxy",
                input: "\(server.user)@\(server.host) (via \(server.proxyJump!))",
                error: error,
                suggestedFix: "verify bastion host is reachable and credentials are valid for both hops"
            )
        }
    }

    func disconnect() async {
        reconnectTask?.cancel()
        reconnectTask = nil

        do {
            try await session.disconnect()
        } catch {
            errorMessage = formatError(
                operation: "disconnect",
                input: currentPath.isEmpty ? "/" : currentPath,
                error: error,
                suggestedFix: "retry disconnect or relaunch if the session was already closed remotely"
            )
        }

        isConnected = false
        connectedUsername = ""
        connectedHost = ""
        connectedAuthConfig = nil
        connectedProxyJump = nil
        connectedPort = 22
        homePath = ""
        files = []
        currentPath = ""
    }

    /// Heartbeat check and auto-reconnect for long-lived windows.
    func ensureConnected() async {
        guard isConnected, let auth = connectedAuthConfig else { return }

        do {
            // Quick heartbeat
            _ = try await session.resolvePath(atPath: ".")
        } catch {
            // Connection lost, attempt reauth/reconnect
            _ = await runKinitKlog()
            
            do {
                let knownHostKey = HostKeyStore.load(for: connectedHost)
                let validator = TOFUHostKeyValidator(expectedOpenSSHKey: knownHostKey)
                if let proxyJump = connectedProxyJump {
                    _ = try await session.connectViaProxy(
                        host: connectedHost,
                        port: connectedPort,
                        proxyJump: proxyJump,
                        username: connectedUsername,
                        auth: auth,
                        hostKeyValidator: .custom(validator)
                    )
                } else {
                    _ = try await session.connect(
                        host: connectedHost,
                        username: connectedUsername,
                        auth: auth,
                        hostKeyValidator: .custom(validator)
                    )
                }
                errorMessage = nil
            } catch {
                errorMessage = "Re-authentication failed: \(error.localizedDescription). Suggested fix: check your credentials and network connection."
                isConnected = false
            }
        }
    }

    private func startReconnectionTimer() {
        reconnectTask?.cancel()
        reconnectTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000) // 5 minutes
                await ensureConnected()
            }
        }
    }

    /// Runs kinit and klog locally to refresh credentials for academic/HPC users.
    /// Gated behind the "enableKerberosRenewal" preference (default: off).
    private func runKinitKlog() async -> Bool {
        guard UserDefaults.standard.bool(forKey: DefaultsKey.enableKerberosRenewal) else {
            return false
        }

        let kinitPath = "/usr/bin/kinit"
        let klogPath = "/usr/bin/klog"

        let kinitSuccess = await runProcess(path: kinitPath, args: ["-R"])
        let klogSuccess = await runProcess(path: klogPath, args: [])

        return kinitSuccess || klogSuccess
    }

    private func runProcess(path: String, args: [String]) async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
        }
    }

    func listDirectory() async {
        guard !currentPath.isEmpty else {
            files = []
            return
        }

        do {
            files = try await session.listDirectory(atPath: currentPath)
            errorMessage = nil
        } catch {
            files = []
            errorMessage = formatError(
                operation: "list directory",
                input: currentPath,
                error: error,
                suggestedFix: "check path permissions and confirm the remote directory still exists"
            )
        }
    }

    func navigateTo(_ dirname: String) async {
        let candidate: String
        if dirname == ".." {
            candidate = (currentPath as NSString).deletingLastPathComponent
        } else {
            candidate = currentPath.hasSuffix("/")
                ? currentPath + dirname
                : currentPath + "/" + dirname
        }

        do {
            let resolved = try await session.resolvePath(atPath: candidate)
            let newFiles = try await session.listDirectory(atPath: resolved)
            
            currentPath = resolved
            files = newFiles
            errorMessage = nil
        } catch {
            errorMessage = formatError(
                operation: "navigate to",
                input: candidate,
                error: error,
                suggestedFix: "confirm the directory exists and you have read permissions"
            )
        }
    }

    func executeCommand(_ command: String, mergeStreams: Bool = true) async throws -> String {
        try await session.executeCommand(command, mergeStreams: mergeStreams)
    }

    func executeCommandStream(_ command: String) async throws -> AsyncThrowingStream<ExecCommandOutput, Error> {
        try await session.executeCommandStream(command)
    }

    func statFile(atPath path: String) async throws -> UInt64 {
        try await session.statFile(atPath: path)
    }

    func uploadFile(
        localURL: URL,
        to destinationPath: String,
        resumeOffset: UInt64 = 0,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws {
        let remotePath = destinationPath.hasSuffix("/")
            ? destinationPath + localURL.lastPathComponent
            : destinationPath + "/" + localURL.lastPathComponent

        try await session.uploadFile(localURL: localURL, remotePath: remotePath, resumeOffset: resumeOffset, progressHandler: progressHandler)

        if currentPath == destinationPath {
            await listDirectory()
        }
    }

    func uploadFileToPath(
        localURL: URL,
        remotePath: String,
        resumeOffset: UInt64 = 0,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws {
        try await session.uploadFile(localURL: localURL, remotePath: remotePath, resumeOffset: resumeOffset, progressHandler: progressHandler)

        let destinationDir = (remotePath as NSString).deletingLastPathComponent
        if currentPath == destinationDir || currentPath == remotePath {
            await listDirectory()
        }
    }

    func downloadFile(
        remoteFilename: String,
        to localURL: URL,
        size: UInt64,
        resumeOffset: UInt64 = 0,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws {
        let remotePath = currentPath.hasSuffix("/")
            ? currentPath + remoteFilename
            : currentPath + "/" + remoteFilename

        try await session.downloadFile(
            remotePath: remotePath,
            to: localURL,
            size: size,
            resumeOffset: resumeOffset,
            progressHandler: progressHandler
        )
    }

    func downloadFileAtPath(
        remotePath: String,
        to localURL: URL,
        size: UInt64,
        resumeOffset: UInt64 = 0,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws {
        try await session.downloadFile(
            remotePath: remotePath,
            to: localURL,
            size: size,
            resumeOffset: resumeOffset,
            progressHandler: progressHandler
        )
    }

    private func formatError(operation: String, input: String, error: Error, suggestedFix: String) -> String {
        "\(operation.capitalized) failed for \(input): \(error.localizedDescription). Suggested fix: \(suggestedFix)."
    }
}

private actor SFTPSession {
    private var sshClient: SSHClient?
    private var sftpClient: SFTPClient?
    private var bastionClient: SSHClient?

    func connect(
        host: String,
        username: String,
        auth: SSHAuthConfig,
        hostKeyValidator: SSHHostKeyValidator
    ) async throws -> String {
        let authMethod: SSHAuthenticationMethod
        switch auth {
        case let .password(password):
            authMethod = .passwordBased(username: username, password: password)
        case let .sshKey(keyPath, passphrase):
            authMethod = try SSHKeyManager.buildAuthMethod(
                keyPath: keyPath,
                username: username,
                passphrase: passphrase
            )
        }

        let client = try await SSHClient.connect(
            host: host,
            authenticationMethod: authMethod,
            hostKeyValidator: hostKeyValidator,
            reconnect: .always
        )

        let sftp = try await client.openSFTP()
        let resolvedHome = try await sftp.getRealPath(atPath: ".")

        sshClient = client
        sftpClient = sftp

        return resolvedHome
    }

    func connectViaProxy(
        host: String,
        port: Int,
        proxyJump: String,
        username: String,
        auth: SSHAuthConfig,
        hostKeyValidator: SSHHostKeyValidator
    ) async throws -> String {
        let parsed = Self.parseProxyJump(proxyJump, defaultUser: username)

        let bastionAuth: SSHAuthenticationMethod
        switch auth {
        case let .password(password):
            bastionAuth = .passwordBased(username: parsed.user, password: password)
        case let .sshKey(keyPath, passphrase):
            bastionAuth = try SSHKeyManager.buildAuthMethod(
                keyPath: keyPath,
                username: parsed.user,
                passphrase: passphrase
            )
        }

        let bastionHostKey = HostKeyStore.load(for: parsed.host)
        let bastionValidator = TOFUHostKeyValidator(expectedOpenSSHKey: bastionHostKey)

        let bastion = try await SSHClient.connect(
            host: parsed.host,
            port: parsed.port,
            authenticationMethod: bastionAuth,
            hostKeyValidator: .custom(bastionValidator),
            reconnect: .never
        )

        if bastionHostKey == nil, let acceptedKey = bastionValidator.acceptedOpenSSHKey {
            HostKeyStore.save(acceptedKey, for: parsed.host)
        }

        let targetAuth: SSHAuthenticationMethod
        switch auth {
        case let .password(password):
            targetAuth = .passwordBased(username: username, password: password)
        case let .sshKey(keyPath, passphrase):
            targetAuth = try SSHKeyManager.buildAuthMethod(
                keyPath: keyPath,
                username: username,
                passphrase: passphrase
            )
        }

        let targetSettings = SSHClientSettings(
            host: host,
            port: port,
            authenticationMethod: { targetAuth },
            hostKeyValidator: hostKeyValidator
        )

        let client = try await bastion.jump(to: targetSettings)
        let sftp = try await client.openSFTP()
        let resolvedHome = try await sftp.getRealPath(atPath: ".")

        bastionClient = bastion
        sshClient = client
        sftpClient = sftp

        return resolvedHome
    }

    private static func parseProxyJump(
        _ value: String,
        defaultUser: String
    ) -> (user: String, host: String, port: Int) {
        var user = defaultUser
        var host = value
        var port = 22

        if let atIndex = host.firstIndex(of: "@") {
            user = String(host[host.startIndex ..< atIndex])
            host = String(host[host.index(after: atIndex)...])
        }

        if let colonIndex = host.lastIndex(of: ":"),
           let parsedPort = Int(String(host[host.index(after: colonIndex)...]))
        {
            port = parsedPort
            host = String(host[host.startIndex ..< colonIndex])
        }

        return (user, host, port)
    }

    func disconnect() async throws {
        var firstError: Error?

        if let sftpClient {
            do {
                try await sftpClient.close()
            } catch {
                firstError = firstError ?? error
            }
        }

        if let sshClient {
            do {
                try await sshClient.close()
            } catch {
                firstError = firstError ?? error
            }
        }

        if let bastionClient {
            do {
                try await bastionClient.close()
            } catch {
                firstError = firstError ?? error
            }
        }

        self.sftpClient = nil
        self.sshClient = nil
        self.bastionClient = nil

        if let firstError {
            throw firstError
        }
    }

    func listDirectory(atPath path: String) async throws -> [RemoteFileItem] {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        let entries = try await sftp.listDirectory(atPath: path)
        let components = entries.flatMap(\.components)

        return components.compactMap { component in
            let name = component.filename
            if name == "." || name == ".." { return nil }

            let isDir = component.attributes.permissions.map { $0 & 0o040000 != 0 } ?? false
            return RemoteFileItem(
                filename: name,
                isDirectory: isDir,
                size: component.attributes.size ?? 0,
                modificationDate: component.attributes.accessModificationTime?.modificationTime
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.filename.localizedCaseInsensitiveCompare(rhs.filename) == .orderedAscending
        }
    }

    func resolvePath(atPath path: String) async throws -> String {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }
        return try await sftp.getRealPath(atPath: path)
    }

    func executeCommand(_ command: String, mergeStreams: Bool = true) async throws -> String {
        guard let ssh = sshClient else { throw SFTPError.notConnected }
        var buffer = try await ssh.executeCommand(command, mergeStreams: mergeStreams, inShell: true)
        return buffer.readString(length: buffer.readableBytes) ?? ""
    }

    func executeCommandStream(_ command: String) async throws -> AsyncThrowingStream<ExecCommandOutput, Error> {
        guard let ssh = sshClient else { throw SFTPError.notConnected }
        return try await ssh.executeCommandStream(command, inShell: true)
    }

    func statFile(atPath path: String) async throws -> UInt64 {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }
        let attrs = try await sftp.getAttributes(at: path)
        return attrs.size ?? 0
    }

    func uploadFile(
        localURL: URL,
        remotePath: String,
        resumeOffset: UInt64 = 0,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        let fileHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? fileHandle.close() }

        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let totalSize = (attrs[.size] as? UInt64) ?? 0

        if resumeOffset > 0 {
            try fileHandle.seek(toOffset: resumeOffset)
        }

        try await sftp.withFile(
            filePath: remotePath,
            flags: resumeOffset > 0 ? [.write, .create] : [.write, .create, .truncate]
        ) { remoteFile in
            var offset = resumeOffset
            let chunkSize = 4_194_304 // 4 MB
            var lastReportedProgress = -1.0

            while true {
                try Task.checkCancellation()
                let data = try fileHandle.read(upToCount: chunkSize) ?? Data()
                if data.isEmpty { break }

                try await remoteFile.write(ByteBuffer(data: data), at: offset)
                offset += UInt64(data.count)

                if totalSize > 0 {
                    let progress = Double(offset) / Double(totalSize)
                    if progress - lastReportedProgress >= 0.01 || progress >= 1.0 {
                        lastReportedProgress = progress
                        progressHandler(progress)
                    }
                }
            }
        }
    }

    func downloadFile(
        remotePath: String,
        to localURL: URL,
        size: UInt64,
        resumeOffset: UInt64 = 0,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        if resumeOffset == 0 {
            if !FileManager.default.createFile(atPath: localURL.path, contents: nil) {
                throw SFTPError.localFileCreateFailed(path: localURL.path)
            }
        }

        let fileHandle = try FileHandle(forWritingTo: localURL)
        defer { try? fileHandle.close() }

        if resumeOffset > 0 {
            try fileHandle.seek(toOffset: resumeOffset)
        }

        try await sftp.withFile(filePath: remotePath, flags: .read) { remoteFile in
            var offset = resumeOffset
            let chunkSize: UInt32 = 4_194_304 // 4 MB
            var lastReportedProgress = -1.0

            while true {
                try Task.checkCancellation()
                let buffer = try await remoteFile.read(from: offset, length: chunkSize)
                if buffer.readableBytes == 0 { break }

                if let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) {
                    try fileHandle.write(contentsOf: data)
                }

                offset += UInt64(buffer.readableBytes)
                if size > 0 {
                    let progress = Double(offset) / Double(size)
                    if progress - lastReportedProgress >= 0.01 || progress >= 1.0 {
                        lastReportedProgress = progress
                        progressHandler(progress)
                    }
                }
            }
        }
    }
}

private enum HostKeyStore {
    static func load(for host: String) -> String? {
        HostKeyKeychainHelper.load(for: host)
    }

    static func save(_ openSSHKey: String, for host: String) {
        HostKeyKeychainHelper.save(openSSHKey, for: host)
    }
}

private final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let expectedOpenSSHKey: String?
    private let lock = NIOLock()
    private var acceptedKey: String?

    init(expectedOpenSSHKey: String?) {
        self.expectedOpenSSHKey = expectedOpenSSHKey
    }

    var acceptedOpenSSHKey: String? {
        lock.withLock { acceptedKey }
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let observedKey = String(openSSHPublicKey: hostKey)

        if let expectedOpenSSHKey, expectedOpenSSHKey != observedKey {
            validationCompletePromise.fail(
                SFTPError.hostKeyMismatch(expectedOpenSSHKey: expectedOpenSSHKey, observedOpenSSHKey: observedKey)
            )
            return
        }

        lock.withLock {
            acceptedKey = observedKey
        }
        validationCompletePromise.succeed(())
    }
}

enum SFTPError: LocalizedError {
    case notConnected
    case hostKeyMismatch(expectedOpenSSHKey: String, observedOpenSSHKey: String)
    case localFileCreateFailed(path: String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to SFTP server"
        case let .hostKeyMismatch(expectedOpenSSHKey, observedOpenSSHKey):
            return "Host key mismatch. Expected \(expectedOpenSSHKey), received \(observedOpenSSHKey)"
        case let .localFileCreateFailed(path):
            return "Could not create local file at \(path)"
        }
    }
}
