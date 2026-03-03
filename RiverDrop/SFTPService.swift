import Citadel
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOSSH

@MainActor
final class SFTPService: ObservableObject {
    @Published var isConnected = false
    @Published var connectedUsername = ""
    @Published var homePath = ""
    @Published var currentPath = ""
    @Published var files: [RemoteFileItem] = []
    @Published var errorMessage: String?

    private let session = SFTPSession()

    func connect(host: String, username: String, password: String) async {
        let knownHostKey = HostKeyStore.load(for: host)
        let validator = TOFUHostKeyValidator(expectedOpenSSHKey: knownHostKey)

        do {
            let resolvedHome = try await session.connect(
                host: host,
                username: username,
                password: password,
                hostKeyValidator: .custom(validator)
            )

            if knownHostKey == nil, let acceptedKey = validator.acceptedOpenSSHKey {
                HostKeyStore.save(acceptedKey, for: host)
            }

            connectedUsername = username
            homePath = resolvedHome
            currentPath = resolvedHome
            isConnected = true
            errorMessage = nil
            await listDirectory()
        } catch {
            isConnected = false
            connectedUsername = ""
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

    func disconnect() async {
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
        homePath = ""
        files = []
        currentPath = ""
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
            currentPath = try await session.resolvePath(atPath: candidate)
        } catch {
            currentPath = candidate
        }

        await listDirectory()
    }

    func uploadFile(
        localURL: URL,
        to destinationPath: String,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws {
        let remotePath = destinationPath.hasSuffix("/")
            ? destinationPath + localURL.lastPathComponent
            : destinationPath + "/" + localURL.lastPathComponent

        try await session.uploadFile(localURL: localURL, remotePath: remotePath, progressHandler: progressHandler)
        
        if currentPath == destinationPath {
            await listDirectory()
        }
    }

    func uploadFileToPath(
        localURL: URL,
        remotePath: String,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws {
        try await session.uploadFile(localURL: localURL, remotePath: remotePath, progressHandler: progressHandler)
        
        let destinationDir = (remotePath as NSString).deletingLastPathComponent
        if currentPath == destinationDir || currentPath == remotePath {
            await listDirectory()
        }
    }

    func downloadFile(
        remoteFilename: String,
        to localURL: URL,
        size: UInt64,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws {
        let remotePath = currentPath.hasSuffix("/")
            ? currentPath + remoteFilename
            : currentPath + "/" + remoteFilename

        try await session.downloadFile(
            remotePath: remotePath,
            to: localURL,
            size: size,
            progressHandler: progressHandler
        )
    }

    func downloadFileAtPath(
        remotePath: String,
        to localURL: URL,
        size: UInt64,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws {
        try await session.downloadFile(
            remotePath: remotePath,
            to: localURL,
            size: size,
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

    func connect(
        host: String,
        username: String,
        password: String,
        hostKeyValidator: SSHHostKeyValidator
    ) async throws -> String {
        let client = try await SSHClient.connect(
            host: host,
            authenticationMethod: .passwordBased(username: username, password: password),
            hostKeyValidator: hostKeyValidator,
            reconnect: .never
        )

        let sftp = try await client.openSFTP()
        let resolvedHome = try await sftp.getRealPath(atPath: ".")

        sshClient = client
        sftpClient = sftp

        return resolvedHome
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

        self.sftpClient = nil
        self.sshClient = nil

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

    func uploadFile(
        localURL: URL,
        remotePath: String,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        let fileHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? fileHandle.close() }

        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let totalSize = (attrs[.size] as? UInt64) ?? 0

        try await sftp.withFile(filePath: remotePath, flags: [.write, .create, .truncate]) { remoteFile in
            var offset: UInt64 = 0
            let chunkSize = 32_768

            while true {
                let data = try fileHandle.read(upToCount: chunkSize) ?? Data()
                if data.isEmpty { break }

                try await remoteFile.write(ByteBuffer(data: data), at: offset)
                offset += UInt64(data.count)

                if totalSize > 0 {
                    progressHandler(Double(offset) / Double(totalSize))
                }
            }
        }
    }

    func downloadFile(
        remotePath: String,
        to localURL: URL,
        size: UInt64,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        if !FileManager.default.createFile(atPath: localURL.path, contents: nil) {
            throw SFTPError.localFileCreateFailed(path: localURL.path)
        }

        let fileHandle = try FileHandle(forWritingTo: localURL)
        defer { try? fileHandle.close() }

        try await sftp.withFile(filePath: remotePath, flags: .read) { remoteFile in
            var offset: UInt64 = 0
            let chunkSize: UInt32 = 32_768

            while true {
                let buffer = try await remoteFile.read(from: offset, length: chunkSize)
                if buffer.readableBytes == 0 { break }

                if let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) {
                    try fileHandle.write(contentsOf: data)
                }

                offset += UInt64(buffer.readableBytes)
                if size > 0 {
                    progressHandler(Double(offset) / Double(size))
                }
            }
        }
    }
}

private enum HostKeyStore {
    private static let defaultsPrefix = "KnownHostKey_"

    static func load(for host: String) -> String? {
        UserDefaults.standard.string(forKey: defaultsPrefix + host.lowercased())
    }

    static func save(_ openSSHKey: String, for host: String) {
        UserDefaults.standard.set(openSSHKey, forKey: defaultsPrefix + host.lowercased())
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

        _ = lock.withLock {
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
