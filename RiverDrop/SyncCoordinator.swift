import Foundation
import OSLog

private let syncLogger = Logger(subsystem: "com.riverdrop.app", category: "sync")

@MainActor
@Observable
final class SyncCoordinator {
    var dryRunResult: DryRunResult?
    var isRunningDryRun = false
    var isApplyingSync = false

    private let sftpService: SFTPService
    private let transferManager: TransferManager

    init(sftpService: SFTPService, transferManager: TransferManager) {
        self.sftpService = sftpService
        self.transferManager = transferManager
    }

    // MARK: - Dry Run

    func runDryRunDownload(localDir: URL) async {
        guard sftpService.isConnected else {
            sftpService.errorMessage = "Dry-run failed: not connected to a server. Suggested fix: connect first."
            return
        }
        guard RsyncTransfer.isAvailable else {
            sftpService.errorMessage = "Dry-run failed: rsync is not installed. Suggested fix: install rsync via Homebrew."
            return
        }
        guard let rsyncAuth = resolveRsyncAuth() else {
            sftpService.errorMessage = "Dry-run failed: no auth credentials available. Suggested fix: reconnect to the server."
            return
        }

        isRunningDryRun = true
        dryRunResult = nil

        let rsync = RsyncTransfer()
        do {
            let result = try await rsync.dryRunDownload(
                remotePath: sftpService.currentPath,
                localPath: localDir.path,
                host: sftpService.connectedHost,
                username: sftpService.connectedUsername,
                auth: rsyncAuth
            )
            dryRunResult = result
        } catch is CancellationError {
            // user cancelled, nothing to report
        } catch {
            sftpService.errorMessage = "Dry-run preview failed: \(error.localizedDescription). Suggested fix: verify connection and try again."
        }

        isRunningDryRun = false
    }

    func runDryRunUpload(localDir: URL) async {
        guard sftpService.isConnected else {
            sftpService.errorMessage = "Dry-run failed: not connected to a server. Suggested fix: connect first."
            return
        }
        guard RsyncTransfer.isAvailable else {
            sftpService.errorMessage = "Dry-run failed: rsync is not installed. Suggested fix: install rsync via Homebrew."
            return
        }
        guard let rsyncAuth = resolveRsyncAuth() else {
            sftpService.errorMessage = "Dry-run failed: no auth credentials available. Suggested fix: reconnect to the server."
            return
        }

        isRunningDryRun = true
        dryRunResult = nil

        let rsync = RsyncTransfer()
        do {
            let result = try await rsync.dryRunUpload(
                localPath: localDir.path,
                remotePath: sftpService.currentPath,
                host: sftpService.connectedHost,
                username: sftpService.connectedUsername,
                auth: rsyncAuth
            )
            dryRunResult = result
        } catch is CancellationError {
            // user cancelled, nothing to report
        } catch {
            sftpService.errorMessage = "Dry-run preview failed: \(error.localizedDescription). Suggested fix: verify connection and try again."
        }

        isRunningDryRun = false
    }

    // MARK: - Apply Sync (awaitable)

    func applySyncDownload(localDir: URL) async throws {
        guard sftpService.isConnected else {
            throw SyncError.notConnected
        }
        guard RsyncTransfer.isAvailable else {
            throw SyncError.rsyncUnavailable
        }
        guard let rsyncAuth = resolveRsyncAuth() else {
            throw SyncError.noAuth
        }

        isApplyingSync = true
        defer { isApplyingSync = false }

        let remotePath = sftpService.currentPath
        let dirName = (remotePath as NSString).lastPathComponent
        let item = TransferItem(filename: "Sync: \(dirName)", isUpload: false, destinationDirectory: localDir.path)
        transferManager.insertTransfer(item)
        let itemID = item.id
        let host = sftpService.connectedHost
        let username = sftpService.connectedUsername

        let rsync = RsyncTransfer()
        transferManager.trackRsync(id: itemID, rsync: rsync)
        let start = Date()
        logStart(id: itemID, direction: "download", mode: "rsync-sync-apply", source: remotePath, destination: localDir.path)

        do {
            try await rsync.syncDownload(
                remotePath: remotePath,
                localPath: localDir.path,
                host: host,
                username: username,
                auth: rsyncAuth
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.transferManager.updateProgress(id: itemID, progress: progress)
                }
            }
            transferManager.updateStatus(id: itemID, status: .completed)
            logCompleted(id: itemID, direction: "download", mode: "rsync-sync-apply", start: start)
            dryRunResult = nil
        } catch is CancellationError {
            transferManager.updateStatus(id: itemID, status: .cancelled)
            logCancelled(id: itemID, direction: "download", mode: "rsync-sync-apply", start: start)
            transferManager.cleanupTask(id: itemID)
            throw CancellationError()
        } catch {
            transferManager.updateStatus(id: itemID, status: .failed)
            logFailed(id: itemID, direction: "download", mode: "rsync-sync-apply", start: start, error: error)
            transferManager.cleanupTask(id: itemID)
            throw error
        }
        transferManager.cleanupTask(id: itemID)
    }

    func applySyncUpload(localDir: URL) async throws {
        guard sftpService.isConnected else {
            throw SyncError.notConnected
        }
        guard RsyncTransfer.isAvailable else {
            throw SyncError.rsyncUnavailable
        }
        guard let rsyncAuth = resolveRsyncAuth() else {
            throw SyncError.noAuth
        }

        isApplyingSync = true
        defer { isApplyingSync = false }

        let remotePath = sftpService.currentPath
        let dirName = localDir.lastPathComponent
        let item = TransferItem(filename: "Sync: \(dirName)", isUpload: true, destinationDirectory: remotePath)
        transferManager.insertTransfer(item)
        let itemID = item.id
        let host = sftpService.connectedHost
        let username = sftpService.connectedUsername

        let rsync = RsyncTransfer()
        transferManager.trackRsync(id: itemID, rsync: rsync)
        let start = Date()
        logStart(id: itemID, direction: "upload", mode: "rsync-sync-apply", source: localDir.path, destination: remotePath)

        do {
            try await rsync.syncUpload(
                localPath: localDir.path,
                remotePath: remotePath,
                host: host,
                username: username,
                auth: rsyncAuth
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.transferManager.updateProgress(id: itemID, progress: progress)
                }
            }
            transferManager.updateStatus(id: itemID, status: .completed)
            logCompleted(id: itemID, direction: "upload", mode: "rsync-sync-apply", start: start)
            dryRunResult = nil
        } catch is CancellationError {
            transferManager.updateStatus(id: itemID, status: .cancelled)
            logCancelled(id: itemID, direction: "upload", mode: "rsync-sync-apply", start: start)
            transferManager.cleanupTask(id: itemID)
            throw CancellationError()
        } catch {
            transferManager.updateStatus(id: itemID, status: .failed)
            logFailed(id: itemID, direction: "upload", mode: "rsync-sync-apply", start: start, error: error)
            transferManager.cleanupTask(id: itemID)
            throw error
        }
        transferManager.cleanupTask(id: itemID)
    }

    // MARK: - Auth Resolution

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

    // MARK: - Directory Sync (fire-and-forget)

    func syncDirectory(localDir: URL) {
        guard sftpService.isConnected else {
            transferManager.setErrorMessage("Sync failed: not connected to a server. Suggested fix: connect first.")
            return
        }
        guard RsyncTransfer.isAvailable else {
            transferManager.setErrorMessage("Sync failed: rsync is not installed. Suggested fix: install rsync via Homebrew.")
            return
        }
        guard let rsyncAuth = resolveRsyncAuth() else {
            transferManager.setErrorMessage("Sync failed: no auth credentials available. Suggested fix: reconnect to the server.")
            return
        }

        let remotePath = sftpService.currentPath
        let dirName = (remotePath as NSString).lastPathComponent
        let item = TransferItem(filename: "Sync: \(dirName)", isUpload: false, destinationDirectory: localDir.path)
        transferManager.insertTransfer(item)
        let itemID = item.id
        let host = sftpService.connectedHost
        let username = sftpService.connectedUsername

        let task = Task {
            let rsync = RsyncTransfer()
            transferManager.trackRsync(id: itemID, rsync: rsync)
            let start = Date()
            logStart(id: itemID, direction: "download", mode: "rsync-sync", source: remotePath, destination: localDir.path)

            do {
                try await rsync.syncDownload(
                    remotePath: remotePath,
                    localPath: localDir.path,
                    host: host,
                    username: username,
                    auth: rsyncAuth
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.transferManager.updateProgress(id: itemID, progress: progress)
                    }
                }
                transferManager.updateStatus(id: itemID, status: .completed)
                logCompleted(id: itemID, direction: "download", mode: "rsync-sync", start: start)
            } catch is CancellationError {
                transferManager.updateStatus(id: itemID, status: .cancelled)
                logCancelled(id: itemID, direction: "download", mode: "rsync-sync", start: start)
            } catch {
                transferManager.updateStatus(id: itemID, status: .failed)
                transferManager.setErrorMessage("Directory sync failed from \(remotePath) to \(localDir.path): \(error.localizedDescription). Suggested fix: verify connection and try again.")
                logFailed(id: itemID, direction: "download", mode: "rsync-sync", start: start, error: error)
            }
            transferManager.cleanupTask(id: itemID)
        }
        transferManager.trackTask(id: itemID, task: task)
    }

    func syncUpload(localDir: URL) {
        guard sftpService.isConnected else {
            transferManager.setErrorMessage("Sync failed: not connected to a server. Suggested fix: connect first.")
            return
        }
        guard RsyncTransfer.isAvailable else {
            transferManager.setErrorMessage("Sync failed: rsync is not installed. Suggested fix: install rsync via Homebrew.")
            return
        }
        guard let rsyncAuth = resolveRsyncAuth() else {
            transferManager.setErrorMessage("Sync failed: no auth credentials available. Suggested fix: reconnect to the server.")
            return
        }

        let remotePath = sftpService.currentPath
        let dirName = localDir.lastPathComponent
        let item = TransferItem(filename: "Sync: \(dirName)", isUpload: true, destinationDirectory: remotePath)
        transferManager.insertTransfer(item)
        let itemID = item.id
        let host = sftpService.connectedHost
        let username = sftpService.connectedUsername

        let task = Task {
            let rsync = RsyncTransfer()
            transferManager.trackRsync(id: itemID, rsync: rsync)
            let start = Date()
            logStart(id: itemID, direction: "upload", mode: "rsync-sync", source: localDir.path, destination: remotePath)

            do {
                try await rsync.syncUpload(
                    localPath: localDir.path,
                    remotePath: remotePath,
                    host: host,
                    username: username,
                    auth: rsyncAuth
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.transferManager.updateProgress(id: itemID, progress: progress)
                    }
                }
                transferManager.updateStatus(id: itemID, status: .completed)
                logCompleted(id: itemID, direction: "upload", mode: "rsync-sync", start: start)
            } catch is CancellationError {
                transferManager.updateStatus(id: itemID, status: .cancelled)
                logCancelled(id: itemID, direction: "upload", mode: "rsync-sync", start: start)
            } catch {
                transferManager.updateStatus(id: itemID, status: .failed)
                transferManager.setErrorMessage("Directory sync upload failed from \(localDir.path) to \(remotePath): \(error.localizedDescription). Suggested fix: verify connection and try again.")
                logFailed(id: itemID, direction: "upload", mode: "rsync-sync", start: start, error: error)
            }
            transferManager.cleanupTask(id: itemID)
        }
        transferManager.trackTask(id: itemID, task: task)
    }

    // MARK: - Logging Helpers

    private func logStart(id: UUID, direction: String, mode: String, source: String, destination: String) {
        syncLogger.info(
            "Transfer start id=\(id.uuidString, privacy: .public) direction=\(direction, privacy: .public) mode=\(mode, privacy: .public) source=\(source, privacy: .public) destination=\(destination, privacy: .public)"
        )
    }

    private func logCompleted(id: UUID, direction: String, mode: String, start: Date) {
        let duration = max(Date().timeIntervalSince(start), 0.001)
        syncLogger.info(
            "Transfer completed id=\(id.uuidString, privacy: .public) direction=\(direction, privacy: .public) mode=\(mode, privacy: .public) duration_s=\(duration, format: .fixed(precision: 3))"
        )
    }

    private func logCancelled(id: UUID, direction: String, mode: String, start: Date) {
        let duration = max(Date().timeIntervalSince(start), 0.001)
        syncLogger.notice(
            "Transfer cancelled id=\(id.uuidString, privacy: .public) direction=\(direction, privacy: .public) mode=\(mode, privacy: .public) duration_s=\(duration, format: .fixed(precision: 3))"
        )
    }

    private func logFailed(id: UUID, direction: String, mode: String, start: Date, error: Error) {
        let duration = max(Date().timeIntervalSince(start), 0.001)
        syncLogger.error(
            "Transfer failed id=\(id.uuidString, privacy: .public) direction=\(direction, privacy: .public) mode=\(mode, privacy: .public) duration_s=\(duration, format: .fixed(precision: 3)) error=\(error.localizedDescription, privacy: .public)"
        )
    }
}

enum SyncError: LocalizedError {
    case notConnected
    case rsyncUnavailable
    case noAuth

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "Sync failed: not connected to a server. Suggested fix: connect first."
        case .rsyncUnavailable:
            "Sync failed: rsync is not installed. Suggested fix: install rsync via Homebrew."
        case .noAuth:
            "Sync failed: no auth credentials available. Suggested fix: reconnect to the server."
        }
    }
}
