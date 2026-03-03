import AppKit
import Foundation

struct TransferItem: Identifiable {
    let id = UUID()
    let filename: String
    let isUpload: Bool
    var progress: Double = 0
    var status: TransferStatus = .inProgress

    enum TransferStatus: String {
        case inProgress = "Transferring"
        case completed = "Completed"
        case failed = "Failed"
        case skipped = "Skipped"
        case cancelled = "Cancelled"
    }
}

enum ConflictResolution {
    case replace, rename, cancel
}

private let rsyncThreshold: UInt64 = 100 * 1024 * 1024 // 100 MB

@MainActor
final class TransferManager: ObservableObject {
    @Published var transfers: [TransferItem] = []

    var onDownloadCompleted: ((String) -> Void)?

    private let sftpService: SFTPService
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var activeRsyncs: [UUID: RsyncTransfer] = [:]

    private enum RemoteDownloadSource {
        case filename(String)
        case fullPath(String)
    }

    init(sftpService: SFTPService) {
        self.sftpService = sftpService
    }

    // MARK: - Cancel

    func cancelTransfer(id: UUID) {
        activeRsyncs[id]?.cancel()
        activeRsyncs[id] = nil

        activeTasks[id]?.cancel()
        activeTasks[id] = nil

        updateStatus(id: id, status: .cancelled)
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

        if isDirectory.boolValue {
            recordSkippedTransfer(filename: localURL.lastPathComponent, isUpload: true)
            sftpService.errorMessage = "Upload skipped for \(localURL.path): directory uploads are not supported. Suggested fix: select files inside the folder or archive the folder first."
            return
        }

        let destinationPath = sftpService.currentPath
        let filename = localURL.lastPathComponent

        Task {
            if sftpService.files.contains(where: { $0.filename == filename && !$0.isDirectory }) {
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
        let item = TransferItem(filename: remoteName, isUpload: true)
        transfers.insert(item, at: 0)
        let itemID = item.id
        let remotePath = destinationPath.hasSuffix("/")
            ? destinationPath + remoteName
            : destinationPath + "/" + remoteName

        let task = Task {
            do {
                try await sftpService.uploadFileToPath(localURL: localURL, remotePath: remotePath) { [weak self] progress in
                    Task { @MainActor in
                        self?.updateProgress(id: itemID, progress: progress)
                    }
                }
                updateStatus(id: itemID, status: .completed)
            } catch is CancellationError {
                updateStatus(id: itemID, status: .cancelled)
            } catch {
                updateStatus(id: itemID, status: .failed)
                sftpService.errorMessage = transferFailureMessage(
                    operation: "upload",
                    source: localURL.path,
                    destination: remotePath,
                    error: error,
                    suggestedFix: "check remote write permissions and available disk space"
                )
            }
            cleanupTask(id: itemID)
        }
        activeTasks[itemID] = task
    }

    private func doUpload(localURL: URL, to destinationPath: String) {
        let item = TransferItem(filename: localURL.lastPathComponent, isUpload: true)
        transfers.insert(item, at: 0)
        let itemID = item.id

        let fileSize = fileSize(at: localURL)
        let useRsync = fileSize >= rsyncThreshold && RsyncTransfer.isAvailable && retrievePassword() != nil

        let task = Task {
            if useRsync {
                let rsync = RsyncTransfer()
                activeRsyncs[itemID] = rsync

                let remotePath = destinationPath.hasSuffix("/")
                    ? destinationPath + localURL.lastPathComponent
                    : destinationPath + "/" + localURL.lastPathComponent

                do {
                    try await rsync.upload(
                        localPath: localURL.path,
                        remotePath: remotePath,
                        host: sftpService.connectedHost,
                        username: sftpService.connectedUsername,
                        password: retrievePassword()!
                    ) { [weak self] progress in
                        Task { @MainActor in
                            self?.updateProgress(id: itemID, progress: progress)
                        }
                    }
                    updateStatus(id: itemID, status: .completed)
                    if sftpService.currentPath == destinationPath {
                        await sftpService.listDirectory()
                    }
                    cleanupTask(id: itemID)
                    return
                } catch is CancellationError {
                    updateStatus(id: itemID, status: .cancelled)
                    cleanupTask(id: itemID)
                    return
                } catch {
                    // rsync failed — fall back to SFTP
                    activeRsyncs[itemID] = nil
                    updateProgress(id: itemID, progress: 0)
                }
            }

            // SFTP path
            do {
                try await sftpService.uploadFile(localURL: localURL, to: destinationPath) { [weak self] progress in
                    Task { @MainActor in
                        self?.updateProgress(id: itemID, progress: progress)
                    }
                }
                updateStatus(id: itemID, status: .completed)
            } catch is CancellationError {
                updateStatus(id: itemID, status: .cancelled)
            } catch {
                updateStatus(id: itemID, status: .failed)
                sftpService.errorMessage = transferFailureMessage(
                    operation: "upload",
                    source: localURL.path,
                    destination: destinationPath,
                    error: error,
                    suggestedFix: "check remote write permissions and available disk space"
                )
            }
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
        let item = TransferItem(filename: displayName, isUpload: false)
        transfers.insert(item, at: 0)
        let itemID = item.id

        let useRsync = size >= rsyncThreshold && RsyncTransfer.isAvailable && retrievePassword() != nil

        let task = Task {
            if useRsync {
                let rsync = RsyncTransfer()
                activeRsyncs[itemID] = rsync

                do {
                    try await rsync.download(
                        remotePath: fullRemotePath,
                        localPath: localURL.path,
                        host: sftpService.connectedHost,
                        username: sftpService.connectedUsername,
                        password: retrievePassword()!
                    ) { [weak self] progress in
                        Task { @MainActor in
                            self?.updateProgress(id: itemID, progress: progress)
                        }
                    }
                    updateStatus(id: itemID, status: .completed)
                    if let name = notifyFilename {
                        onDownloadCompleted?(name)
                    }
                    cleanupTask(id: itemID)
                    return
                } catch is CancellationError {
                    updateStatus(id: itemID, status: .cancelled)
                    cleanupTask(id: itemID)
                    return
                } catch {
                    // rsync failed — fall back to SFTP
                    activeRsyncs[itemID] = nil
                    updateProgress(id: itemID, progress: 0)
                    // Clean up partial download
                    try? FileManager.default.removeItem(at: localURL)
                }
            }

            // SFTP path
            do {
                switch source {
                case let .filename(remoteFilename):
                    try await sftpService.downloadFile(
                        remoteFilename: remoteFilename,
                        to: localURL,
                        size: size
                    ) { [weak self] progress in
                        Task { @MainActor in
                            self?.updateProgress(id: itemID, progress: progress)
                        }
                    }
                case let .fullPath(remotePath):
                    try await sftpService.downloadFileAtPath(
                        remotePath: remotePath,
                        to: localURL,
                        size: size
                    ) { [weak self] progress in
                        Task { @MainActor in
                            self?.updateProgress(id: itemID, progress: progress)
                        }
                    }
                }

                updateStatus(id: itemID, status: .completed)
                if let name = notifyFilename {
                    onDownloadCompleted?(name)
                }
            } catch is CancellationError {
                updateStatus(id: itemID, status: .cancelled)
            } catch {
                updateStatus(id: itemID, status: .failed)
                sftpService.errorMessage = transferFailureMessage(
                    operation: "download",
                    source: sourceLabel,
                    destination: localURL.path,
                    error: error,
                    suggestedFix: "check local write permissions and confirm the remote file still exists"
                )
            }
            cleanupTask(id: itemID)
        }
        activeTasks[itemID] = task
    }

    // MARK: - Rsync Helpers

    private func retrievePassword() -> String? {
        let host = sftpService.connectedHost
        let username = sftpService.connectedUsername
        guard !host.isEmpty, !username.isEmpty else { return nil }
        return try? KeychainHelper.load(username: username, host: host)
    }

    private func fileSize(at url: URL) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? UInt64) ?? 0
    }

    private func cleanupTask(id: UUID) {
        activeTasks[id] = nil
        activeRsyncs[id] = nil
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

    // MARK: - Progress

    private func updateProgress(id: UUID, progress: Double) {
        if let idx = transfers.firstIndex(where: { $0.id == id }) {
            transfers[idx].progress = progress
        }
    }

    private func updateStatus(id: UUID, status: TransferItem.TransferStatus) {
        if let idx = transfers.firstIndex(where: { $0.id == id }) {
            transfers[idx].status = status
            if status == .completed {
                transfers[idx].progress = 1.0
            }
        }
    }

    private func recordSkippedTransfer(filename: String, isUpload: Bool) {
        var item = TransferItem(filename: filename, isUpload: isUpload)
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
}
