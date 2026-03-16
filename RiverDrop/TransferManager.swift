import AppKit
import Foundation
import OSLog

private let transferLogger = Logger(subsystem: "com.riverdrop.app", category: "transfer")

@MainActor
@Observable
final class TransferManager {
    var transfers: [TransferItem] = []

    var onDownloadCompleted: ((String) -> Void)?

    private let sftpService: SFTPService
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var activeRsyncs: [UUID: RsyncTransfer] = [:]
    private let transferThrottle = TransferThrottle(maxConcurrent: 4)
    private var remoteRsyncAvailable: Bool?

    private var _syncCoordinator: SyncCoordinator?
    var syncCoordinator: SyncCoordinator {
        if let existing = _syncCoordinator { return existing }
        let coordinator = SyncCoordinator(sftpService: sftpService, transferManager: self)
        _syncCoordinator = coordinator
        return coordinator
    }

    // MARK: - Forwarding Properties (preserve call-site compatibility)

    var dryRunResult: DryRunResult? {
        get { syncCoordinator.dryRunResult }
        set { syncCoordinator.dryRunResult = newValue }
    }

    var isRunningDryRun: Bool {
        syncCoordinator.isRunningDryRun
    }

    var isApplyingSync: Bool {
        syncCoordinator.isApplyingSync
    }

    // MARK: - Forwarding Methods (preserve call-site compatibility)

    func runDryRunDownload(localDir: URL) async {
        await syncCoordinator.runDryRunDownload(localDir: localDir)
    }

    func runDryRunUpload(localDir: URL) async {
        await syncCoordinator.runDryRunUpload(localDir: localDir)
    }

    func applySyncDownload(localDir: URL) async throws {
        try await syncCoordinator.applySyncDownload(localDir: localDir)
    }

    func applySyncUpload(localDir: URL) async throws {
        try await syncCoordinator.applySyncUpload(localDir: localDir)
    }

    func syncDirectory(localDir: URL) {
        syncCoordinator.syncDirectory(localDir: localDir)
    }

    func syncUpload(localDir: URL) {
        syncCoordinator.syncUpload(localDir: localDir)
    }

    private enum RemoteDownloadSource {
        case filename(String)
        case fullPath(String)
    }

    init(sftpService: SFTPService) {
        self.sftpService = sftpService
    }

    // MARK: - Internal Helpers (used by SyncCoordinator)

    func insertTransfer(_ item: TransferItem) {
        transfers.insert(item, at: 0)
    }

    func trackRsync(id: UUID, rsync: RsyncTransfer) {
        activeRsyncs[id] = rsync
    }

    func trackTask(id: UUID, task: Task<Void, Never>) {
        activeTasks[id] = task
    }

    func setErrorMessage(_ message: String) {
        sftpService.errorMessage = message
    }

    func updateProgress(id: UUID, progress: Double) {
        if let idx = transfers.firstIndex(where: { $0.id == id }) {
            transfers[idx].progress = progress
        }
    }

    func updateStatus(id: UUID, status: TransferItem.TransferStatus) {
        if let idx = transfers.firstIndex(where: { $0.id == id }) {
            transfers[idx].status = status
            if status == .completed {
                transfers[idx].progress = 1.0
            }
        }
    }

    func cleanupTask(id: UUID) {
        activeTasks[id] = nil
        activeRsyncs[id] = nil
    }

    // MARK: - Cancel

    func cancelTransfer(id: UUID) {
        activeRsyncs[id]?.cancel()
        activeRsyncs[id] = nil

        activeTasks[id]?.cancel()
        activeTasks[id] = nil
    }

    // MARK: - Upload

    func upload(localURL: URL) {
        guard sftpService.isConnected else {
            sftpService.errorMessage = "Upload failed for \(localURL.path): not connected to an SFTP server. Suggested fix: connect to a server and retry."
            return
        }

        guard localURL.isFileURL else {
            recordSkippedTransfer(filename: localURL.lastPathComponent, isUpload: true)
            sftpService.errorMessage = "Upload skipped for \(localURL.absoluteString): only local file paths are supported. Suggested fix: drop a file from the local pane or Finder."
            return
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory) else {
            recordSkippedTransfer(filename: localURL.lastPathComponent, isUpload: true)
            sftpService.errorMessage = "Upload skipped for \(localURL.path): source file was not found. Suggested fix: refresh the local pane and retry."
            return
        }

        let rsyncAuth = resolveRsyncAuth()
        let useRsync = RsyncTransfer.isAvailable && rsyncAuth != nil

        if isDirectory.boolValue && !useRsync {
            recordSkippedTransfer(filename: localURL.lastPathComponent, isUpload: true)
            sftpService.errorMessage = "Upload skipped for \(localURL.path): directory uploads require a Pro subscription and rsync. Suggested fix: upgrade to Pro or archive the folder first."
            return
        }

        let destinationPath = sftpService.currentPath
        let filename = localURL.lastPathComponent

        Task {
            if sftpService.files.contains(where: { $0.filename == filename }) {
                let resolution = await promptConflict(filename: filename, direction: "upload")
                switch resolution {
                case .cancel: return
                case .rename:
                    let newName = uniqueRemoteName(for: filename)
                    uploadRenamed(localURL: localURL, remoteName: newName, to: destinationPath)
                    return
                case .replace:
                    break
                }
            }
            doUpload(localURL: localURL, to: destinationPath)
        }
    }

    private func uploadRenamed(localURL: URL, remoteName: String, to destinationPath: String) {
        let item = TransferItem(filename: remoteName, isUpload: true, destinationDirectory: destinationPath)
        transfers.insert(item, at: 0)
        let itemID = item.id
        let transferSize = localFileSize(at: localURL)
        let remotePath = destinationPath.hasSuffix("/")
            ? destinationPath + remoteName
            : destinationPath + "/" + remoteName

        let rsyncAuth = resolveRsyncAuth()
        let useRsync = RsyncTransfer.isAvailable && rsyncAuth != nil

        let task = Task {
            var sftpResumeOffset: UInt64 = 0
            if useRsync, let rsyncAuth {
                let rsync = RsyncTransfer()
                activeRsyncs[itemID] = rsync
                let rsyncStart = Date()
                logTransferStart(
                    id: itemID,
                    direction: "upload",
                    mode: "rsync",
                    source: localURL.path,
                    destination: remotePath,
                    bytes: transferSize
                )

                do {
                    try await rsync.upload(
                        localPath: localURL.path,
                        remotePath: remotePath,
                        host: sftpService.connectedHost,
                        port: sftpService.connectedPort,
                        username: sftpService.connectedUsername,
                        auth: rsyncAuth,
                        proxyJump: sftpService.connectedProxyJump
                    ) { [weak self] progress in
                        Task { @MainActor in
                            self?.updateProgress(id: itemID, progress: progress)
                        }
                    }
                    updateStatus(id: itemID, status: .completed)
                    logTransferCompleted(
                        id: itemID,
                        direction: "upload",
                        mode: "rsync",
                        bytes: transferSize,
                        startedAt: rsyncStart
                    )
                    if sftpService.currentPath == destinationPath {
                        await sftpService.listDirectory()
                    }
                    cleanupTask(id: itemID)
                    return
                } catch is CancellationError {
                    updateStatus(id: itemID, status: .cancelled)
                    logTransferCancelled(
                        id: itemID,
                        direction: "upload",
                        mode: "rsync",
                        bytes: transferSize,
                        startedAt: rsyncStart
                    )
                    cleanupTask(id: itemID)
                    return
                } catch {
                    // rsync failed -- fall back to SFTP if it's a file
                    activeRsyncs[itemID] = nil
                    var isDir = ObjCBool(false)
                    if FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir), !isDir.boolValue {
                        updateProgress(id: itemID, progress: 0)
                        logTransferFailed(
                            id: itemID,
                            direction: "upload",
                            mode: "rsync",
                            bytes: transferSize,
                            startedAt: rsyncStart,
                            error: error
                        )
                        transferLogger.notice("Transfer fallback id=\(itemID.uuidString, privacy: .public) from=rsync to=sftp")
                        do {
                            sftpResumeOffset = try await sftpService.statFile(atPath: remotePath)
                        } catch {
                            sftpResumeOffset = 0
                        }
                    } else {
                        updateStatus(id: itemID, status: .failed)
                        sftpService.errorMessage = transferFailureMessage(
                            operation: "upload",
                            source: localURL.path,
                            destination: remotePath,
                            error: error,
                            suggestedFix: "check remote write permissions and available disk space"
                        )
                        cleanupTask(id: itemID)
                        return
                    }
                }
            }

            // SFTP path
            await transferThrottle.acquire()
            let sftpStart = Date()
            logTransferStart(
                id: itemID,
                direction: "upload",
                mode: "sftp",
                source: localURL.path,
                destination: remotePath,
                bytes: transferSize
            )
            do {
                try await sftpService.uploadFileToPath(localURL: localURL, remotePath: remotePath, resumeOffset: sftpResumeOffset) { [weak self] progress in
                    Task { @MainActor in
                        self?.updateProgress(id: itemID, progress: progress)
                    }
                }
                updateStatus(id: itemID, status: .completed)
                logTransferCompleted(
                    id: itemID,
                    direction: "upload",
                    mode: "sftp",
                    bytes: transferSize,
                    startedAt: sftpStart
                )
            } catch is CancellationError {
                updateStatus(id: itemID, status: .cancelled)
                logTransferCancelled(
                    id: itemID,
                    direction: "upload",
                    mode: "sftp",
                    bytes: transferSize,
                    startedAt: sftpStart
                )
            } catch {
                updateStatus(id: itemID, status: .failed)
                sftpService.errorMessage = transferFailureMessage(
                    operation: "upload",
                    source: localURL.path,
                    destination: remotePath,
                    error: error,
                    suggestedFix: "check remote write permissions and available disk space"
                )
                logTransferFailed(
                    id: itemID,
                    direction: "upload",
                    mode: "sftp",
                    bytes: transferSize,
                    startedAt: sftpStart,
                    error: error
                )
            }
            await transferThrottle.release()
            cleanupTask(id: itemID)
        }
        activeTasks[itemID] = task
    }

    private func doUpload(localURL: URL, to destinationPath: String) {
        let item = TransferItem(filename: localURL.lastPathComponent, isUpload: true, destinationDirectory: destinationPath)
        transfers.insert(item, at: 0)
        let itemID = item.id
        let transferSize = localFileSize(at: localURL)
        let remotePath = destinationPath.hasSuffix("/")
            ? destinationPath + localURL.lastPathComponent
            : destinationPath + "/" + localURL.lastPathComponent

        let rsyncAuth = resolveRsyncAuth()
        let useRsync = RsyncTransfer.isAvailable && rsyncAuth != nil

        let task = Task {
            var sftpResumeOffset: UInt64 = 0
            if useRsync, let rsyncAuth {
                let rsync = RsyncTransfer()
                activeRsyncs[itemID] = rsync
                let rsyncStart = Date()
                logTransferStart(
                    id: itemID,
                    direction: "upload",
                    mode: "rsync",
                    source: localURL.path,
                    destination: remotePath,
                    bytes: transferSize
                )

                do {
                    try await rsync.upload(
                        localPath: localURL.path,
                        remotePath: remotePath,
                        host: sftpService.connectedHost,
                        port: sftpService.connectedPort,
                        username: sftpService.connectedUsername,
                        auth: rsyncAuth,
                        proxyJump: sftpService.connectedProxyJump
                    ) { [weak self] progress in
                        Task { @MainActor in
                            self?.updateProgress(id: itemID, progress: progress)
                        }
                    }
                    updateStatus(id: itemID, status: .completed)
                    logTransferCompleted(
                        id: itemID,
                        direction: "upload",
                        mode: "rsync",
                        bytes: transferSize,
                        startedAt: rsyncStart
                    )
                    if sftpService.currentPath == destinationPath {
                        await sftpService.listDirectory()
                    }
                    cleanupTask(id: itemID)
                    return
                } catch is CancellationError {
                    updateStatus(id: itemID, status: .cancelled)
                    logTransferCancelled(
                        id: itemID,
                        direction: "upload",
                        mode: "rsync",
                        bytes: transferSize,
                        startedAt: rsyncStart
                    )
                    cleanupTask(id: itemID)
                    return
                } catch {
                    // rsync failed -- fall back to SFTP if it's a file
                    activeRsyncs[itemID] = nil
                    var isDir = ObjCBool(false)
                    if FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir), !isDir.boolValue {
                        updateProgress(id: itemID, progress: 0)
                        logTransferFailed(
                            id: itemID,
                            direction: "upload",
                            mode: "rsync",
                            bytes: transferSize,
                            startedAt: rsyncStart,
                            error: error
                        )
                        transferLogger.notice("Transfer fallback id=\(itemID.uuidString, privacy: .public) from=rsync to=sftp")
                        do {
                            sftpResumeOffset = try await sftpService.statFile(atPath: remotePath)
                        } catch {
                            sftpResumeOffset = 0
                        }
                    } else {
                        updateStatus(id: itemID, status: .failed)
                        sftpService.errorMessage = transferFailureMessage(
                            operation: "upload",
                            source: localURL.path,
                            destination: destinationPath,
                            error: error,
                            suggestedFix: "check remote write permissions and available disk space"
                        )
                        cleanupTask(id: itemID)
                        return
                    }
                }
            }

            // SFTP path
            await transferThrottle.acquire()
            let sftpStart = Date()
            logTransferStart(
                id: itemID,
                direction: "upload",
                mode: "sftp",
                source: localURL.path,
                destination: remotePath,
                bytes: transferSize
            )
            do {
                try await sftpService.uploadFile(localURL: localURL, to: destinationPath, resumeOffset: sftpResumeOffset) { [weak self] progress in
                    Task { @MainActor in
                        self?.updateProgress(id: itemID, progress: progress)
                    }
                }
                updateStatus(id: itemID, status: .completed)
                logTransferCompleted(
                    id: itemID,
                    direction: "upload",
                    mode: "sftp",
                    bytes: transferSize,
                    startedAt: sftpStart
                )
            } catch is CancellationError {
                updateStatus(id: itemID, status: .cancelled)
                logTransferCancelled(
                    id: itemID,
                    direction: "upload",
                    mode: "sftp",
                    bytes: transferSize,
                    startedAt: sftpStart
                )
            } catch {
                updateStatus(id: itemID, status: .failed)
                sftpService.errorMessage = transferFailureMessage(
                    operation: "upload",
                    source: localURL.path,
                    destination: destinationPath,
                    error: error,
                    suggestedFix: "check remote write permissions and available disk space"
                )
                logTransferFailed(
                    id: itemID,
                    direction: "upload",
                    mode: "sftp",
                    bytes: transferSize,
                    startedAt: sftpStart,
                    error: error
                )
            }
            await transferThrottle.release()
            cleanupTask(id: itemID)
        }
        activeTasks[itemID] = task
    }

    // MARK: - Download

    func downloadToDirectory(remoteFilename: String, size: UInt64, localDir: URL) {
        Task {
            var localURL = localDir.appendingPathComponent(remoteFilename)

            if FileManager.default.fileExists(atPath: localURL.path) {
                let resolution = await promptConflict(filename: remoteFilename, direction: "download")
                switch resolution {
                case .cancel: return
                case .rename:
                    localURL = uniqueLocalURL(for: localURL)
                case .replace:
                    do {
                        try FileManager.default.removeItem(at: localURL)
                    } catch {
                        sftpService.errorMessage = transferFailureMessage(
                            operation: "prepare download",
                            source: localURL.path,
                            destination: localDir.path,
                            error: error,
                            suggestedFix: "close applications using the file and verify write permission for the destination folder"
                        )
                        return
                    }
                }
            }

            let finalName = localURL.lastPathComponent
            download(source: .filename(remoteFilename), size: size, to: localURL, notifyFilename: finalName)
        }
    }

    func downloadRemotePathToDirectory(remotePath: String, filename: String, size: UInt64, localDir: URL) {
        Task {
            var localURL = localDir.appendingPathComponent(filename)

            if FileManager.default.fileExists(atPath: localURL.path) {
                let resolution = await promptConflict(filename: filename, direction: "download")
                switch resolution {
                case .cancel: return
                case .rename:
                    localURL = uniqueLocalURL(for: localURL)
                case .replace:
                    do {
                        try FileManager.default.removeItem(at: localURL)
                    } catch {
                        sftpService.errorMessage = transferFailureMessage(
                            operation: "prepare download",
                            source: localURL.path,
                            destination: localDir.path,
                            error: error,
                            suggestedFix: "close applications using the file and verify write permission for the destination folder"
                        )
                        return
                    }
                }
            }

            let finalName = localURL.lastPathComponent
            download(source: .fullPath(remotePath), size: size, to: localURL, notifyFilename: finalName)
        }
    }

    func download(remoteFilename: String, size: UInt64, to localURL: URL, notifyFilename: String? = nil) {
        download(source: .filename(remoteFilename), size: size, to: localURL, notifyFilename: notifyFilename)
    }

    private func download(source: RemoteDownloadSource, size: UInt64, to localURL: URL, notifyFilename: String? = nil) {
        let sourceLabel: String
        let defaultDisplayName: String
        let fullRemotePath: String
        switch source {
        case let .filename(name):
            sourceLabel = name
            defaultDisplayName = name
            fullRemotePath = sftpService.currentPath.hasSuffix("/")
                ? sftpService.currentPath + name
                : sftpService.currentPath + "/" + name
        case let .fullPath(path):
            sourceLabel = path
            defaultDisplayName = (path as NSString).lastPathComponent
            fullRemotePath = path
        }

        let displayName = notifyFilename ?? defaultDisplayName
        let item = TransferItem(filename: displayName, isUpload: false, destinationDirectory: localURL.deletingLastPathComponent().path)
        transfers.insert(item, at: 0)
        let itemID = item.id
        let transferSize = size

        let rsyncAuth = resolveRsyncAuth()
        let useRsync = RsyncTransfer.isAvailable && rsyncAuth != nil

        let task = Task {
            var sftpResumeOffset: UInt64 = 0
            if useRsync, let rsyncAuth {
                let rsync = RsyncTransfer()
                activeRsyncs[itemID] = rsync
                let rsyncStart = Date()
                logTransferStart(
                    id: itemID,
                    direction: "download",
                    mode: "rsync",
                    source: sourceLabel,
                    destination: localURL.path,
                    bytes: transferSize
                )

                do {
                    try await rsync.download(
                        remotePath: fullRemotePath,
                        localPath: localURL.path,
                        host: sftpService.connectedHost,
                        port: sftpService.connectedPort,
                        username: sftpService.connectedUsername,
                        auth: rsyncAuth,
                        proxyJump: sftpService.connectedProxyJump
                    ) { [weak self] progress in
                        Task { @MainActor in
                            self?.updateProgress(id: itemID, progress: progress)
                        }
                    }
                    updateStatus(id: itemID, status: .completed)
                    logTransferCompleted(
                        id: itemID,
                        direction: "download",
                        mode: "rsync",
                        bytes: transferSize,
                        startedAt: rsyncStart
                    )
                    if let name = notifyFilename {
                        onDownloadCompleted?(name)
                    }
                    cleanupTask(id: itemID)
                    return
                } catch is CancellationError {
                    updateStatus(id: itemID, status: .cancelled)
                    logTransferCancelled(
                        id: itemID,
                        direction: "download",
                        mode: "rsync",
                        bytes: transferSize,
                        startedAt: rsyncStart
                    )
                    cleanupTask(id: itemID)
                    return
                } catch {
                    // rsync failed -- fall back to SFTP
                    activeRsyncs[itemID] = nil
                    updateProgress(id: itemID, progress: 0)
                    logTransferFailed(
                        id: itemID,
                        direction: "download",
                        mode: "rsync",
                        bytes: transferSize,
                        startedAt: rsyncStart,
                        error: error
                    )
                    transferLogger.notice("Transfer fallback id=\(itemID.uuidString, privacy: .public) from=rsync to=sftp")
                    // Check partial download size for SFTP resume
                    let localAttrs = try? FileManager.default.attributesOfItem(atPath: localURL.path)
                    sftpResumeOffset = (localAttrs?[.size] as? UInt64) ?? 0
                }
            }

            // SFTP path
            await transferThrottle.acquire()
            let sftpStart = Date()
            logTransferStart(
                id: itemID,
                direction: "download",
                mode: "sftp",
                source: sourceLabel,
                destination: localURL.path,
                bytes: transferSize
            )
            do {
                switch source {
                case let .filename(remoteFilename):
                    try await sftpService.downloadFile(
                        remoteFilename: remoteFilename,
                        to: localURL,
                        size: size,
                        resumeOffset: sftpResumeOffset
                    ) { [weak self] progress in
                        Task { @MainActor in
                            self?.updateProgress(id: itemID, progress: progress)
                        }
                    }
                case let .fullPath(remotePath):
                    try await sftpService.downloadFileAtPath(
                        remotePath: remotePath,
                        to: localURL,
                        size: size,
                        resumeOffset: sftpResumeOffset
                    ) { [weak self] progress in
                        Task { @MainActor in
                            self?.updateProgress(id: itemID, progress: progress)
                        }
                    }
                }

                updateStatus(id: itemID, status: .completed)
                logTransferCompleted(
                    id: itemID,
                    direction: "download",
                    mode: "sftp",
                    bytes: transferSize,
                    startedAt: sftpStart
                )
                if let name = notifyFilename {
                    onDownloadCompleted?(name)
                }
            } catch is CancellationError {
                updateStatus(id: itemID, status: .cancelled)
                logTransferCancelled(
                    id: itemID,
                    direction: "download",
                    mode: "sftp",
                    bytes: transferSize,
                    startedAt: sftpStart
                )
            } catch {
                updateStatus(id: itemID, status: .failed)
                sftpService.errorMessage = transferFailureMessage(
                    operation: "download",
                    source: sourceLabel,
                    destination: localURL.path,
                    error: error,
                    suggestedFix: "check local write permissions and confirm the remote file still exists"
                )
                logTransferFailed(
                    id: itemID,
                    direction: "download",
                    mode: "sftp",
                    bytes: transferSize,
                    startedAt: sftpStart,
                    error: error
                )
            }
            await transferThrottle.release()
            cleanupTask(id: itemID)
        }
        activeTasks[itemID] = task
    }

    // MARK: - Rsync Helpers

    func resolveRsyncAuth() -> RsyncAuth? {
        switch sftpService.connectedAuthConfig {
        case let .password(password):
            return .password(password)
        case let .sshKey(keyPath, passphrase):
            return .sshKey(path: keyPath, passphrase: passphrase)
        case nil:
            return nil
        }
    }

    private enum TransferEngine {
        case sftp
        case rsync
    }

    private func selectEngine(isDirectory: Bool, fileCount: Int, totalBytes: UInt64, singleFileSize: UInt64) -> TransferEngine {
        if isDirectory { return .rsync }
        if fileCount >= 25 || totalBytes >= 20_000_000 { return .rsync }
        if fileCount == 1 && singleFileSize >= 64_000_000 { return .rsync }
        return .sftp
    }

    private func checkRemoteRsync() async -> Bool {
        if let cached = remoteRsyncAvailable { return cached }
        do {
            let output = try await sftpService.executeCommand("command -v rsync")
            let available = !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            remoteRsyncAvailable = available
            return available
        } catch {
            remoteRsyncAvailable = false
            return false
        }
    }

    private func localFileSize(at url: URL) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? UInt64) ?? 0
    }

    // MARK: - Conflict Resolution

    private func promptConflict(filename: String, direction: String) async -> ConflictResolution {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = "File already exists"
            alert.informativeText = "\"\(filename)\" already exists at the \(direction) destination."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Rename")
            alert.addButton(withTitle: "Cancel")

            if let window = NSApp.keyWindow {
                alert.beginSheetModal(for: window) { response in
                    switch response {
                    case .alertFirstButtonReturn: continuation.resume(returning: .replace)
                    case .alertSecondButtonReturn: continuation.resume(returning: .rename)
                    default: continuation.resume(returning: .cancel)
                    }
                }
            } else {
                let response = alert.runModal()
                switch response {
                case .alertFirstButtonReturn: continuation.resume(returning: .replace)
                case .alertSecondButtonReturn: continuation.resume(returning: .rename)
                default: continuation.resume(returning: .cancel)
                }
            }
        }
    }

    private func uniqueLocalURL(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 1
        var candidate: URL
        repeat {
            let name = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            candidate = dir.appendingPathComponent(name)
            counter += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }

    private func uniqueRemoteName(for filename: String) -> String {
        let nsName = filename as NSString
        let stem = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        var counter = 1
        var candidate: String
        repeat {
            candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            counter += 1
        } while sftpService.files.contains(where: { $0.filename == candidate })
        return candidate
    }

    // MARK: - Progress Helpers

    private func recordSkippedTransfer(filename: String, isUpload: Bool) {
        var item = TransferItem(filename: filename, isUpload: isUpload, destinationDirectory: "")
        item.status = .skipped
        transfers.insert(item, at: 0)
    }

    private func transferFailureMessage(
        operation: String,
        source: String,
        destination: String,
        error: Error,
        suggestedFix: String
    ) -> String {
        "\(operation.capitalized) failed from \(source) to \(destination): \(error.localizedDescription). Suggested fix: \(suggestedFix)."
    }

    private func logTransferStart(
        id: UUID,
        direction: String,
        mode: String,
        source: String,
        destination: String,
        bytes: UInt64
    ) {
        transferLogger.info(
            "Transfer start id=\(id.uuidString, privacy: .public) direction=\(direction, privacy: .public) mode=\(mode, privacy: .public) bytes=\(bytes) source=\(source, privacy: .public) destination=\(destination, privacy: .public)"
        )
    }

    private func logTransferCompleted(
        id: UUID,
        direction: String,
        mode: String,
        bytes: UInt64,
        startedAt: Date
    ) {
        let duration = max(Date().timeIntervalSince(startedAt), 0.001)
        let rateMiBPerSecond = bytes == 0 ? 0 : (Double(bytes) / duration) / 1_048_576
        transferLogger.info(
            "Transfer completed id=\(id.uuidString, privacy: .public) direction=\(direction, privacy: .public) mode=\(mode, privacy: .public) duration_s=\(duration, format: .fixed(precision: 3)) rate_mib_s=\(rateMiBPerSecond, format: .fixed(precision: 2)) bytes=\(bytes)"
        )
    }

    private func logTransferCancelled(
        id: UUID,
        direction: String,
        mode: String,
        bytes: UInt64,
        startedAt: Date
    ) {
        let duration = max(Date().timeIntervalSince(startedAt), 0.001)
        transferLogger.notice(
            "Transfer cancelled id=\(id.uuidString, privacy: .public) direction=\(direction, privacy: .public) mode=\(mode, privacy: .public) duration_s=\(duration, format: .fixed(precision: 3)) bytes=\(bytes)"
        )
    }

    private func logTransferFailed(
        id: UUID,
        direction: String,
        mode: String,
        bytes: UInt64,
        startedAt: Date,
        error: Error
    ) {
        let duration = max(Date().timeIntervalSince(startedAt), 0.001)
        transferLogger.error(
            "Transfer failed id=\(id.uuidString, privacy: .public) direction=\(direction, privacy: .public) mode=\(mode, privacy: .public) duration_s=\(duration, format: .fixed(precision: 3)) bytes=\(bytes) error=\(error.localizedDescription, privacy: .public)"
        )
    }
}
