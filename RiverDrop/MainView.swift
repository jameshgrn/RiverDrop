import SwiftUI

struct MainView: View {
    @Environment(SFTPService.self) var sftpService
    @Environment(TransferManager.self) var transferManager

    @AppStorage(DefaultsKey.defaultLocalDirectory) private var defaultLocalDirectory = ""

    @State private var localCurrentDirectory = URL(fileURLWithPath: "/Users/\(NSUserName())/projects")
    @State private var recentlyDownloaded: Set<String> = []
    @State private var showDryRunPreview = false
    @State private var dryRunIsUpload = false
    @State private var stagedDownloads: [StagedItem] = []
    @State private var stagedUploads: [StagedItem] = []
    @State private var remoteSelectedIDs: Set<RemoteFileItem.ID> = []

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                LocalBrowserView(
                    localCurrentDirectory: $localCurrentDirectory,
                    recentlyDownloaded: $recentlyDownloaded,
                    showDryRunPreview: $showDryRunPreview,
                    dryRunIsUpload: $dryRunIsUpload,
                    stagedUploads: $stagedUploads
                )
                .frame(minWidth: 250)

                RemoteBrowserView(
                    remoteSelectedIDs: $remoteSelectedIDs,
                    localCurrentDirectory: $localCurrentDirectory,
                    recentlyDownloaded: $recentlyDownloaded,
                    showDryRunPreview: $showDryRunPreview,
                    dryRunIsUpload: $dryRunIsUpload,
                    stagedDownloads: $stagedDownloads,
                    stagedUploads: $stagedUploads
                )
                .frame(minWidth: 350)
            }
            Divider()
            TransferLogView(
                navigateRemoteTo: navigateRemoteTo,
                localCurrentDirectory: $localCurrentDirectory
            )
            Divider()
            ConnectionFooterView()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text("Remote: \(sftpService.currentPath)")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            ToolbarItem {
                Button("Disconnect") {
                    Task { await sftpService.disconnect() }
                }
            }
        }
        .onAppear {
            if !defaultLocalDirectory.isEmpty {
                localCurrentDirectory = URL(fileURLWithPath: defaultLocalDirectory)
            }
            transferManager.onDownloadCompleted = { filename in
                recentlyDownloaded.insert(filename)
            }
            Task { await navigateRemoteTo(initialRemotePath()) }
        }
        .focusedSceneValue(\.navigateLocalPath, { [self] path in
            navigateLocalToCommandPath(path)
        })
        .focusedSceneValue(\.selectedRemotePaths, selectedRemotePaths)
    }

    // MARK: - Navigation Helpers

    private func initialRemotePath() -> String {
        if !sftpService.homePath.isEmpty {
            return sftpService.homePath
        }
        if !sftpService.currentPath.isEmpty {
            return sftpService.currentPath
        }
        return "."
    }

    private func navigateRemoteTo(_ path: String) async {
        sftpService.currentPath = path
        await sftpService.listDirectory()
        remoteSelectedIDs = []
    }

    private func navigateLocalToCommandPath(_ path: String) {
        if path == AppCommandPayload.openPanel {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Navigate"
            if panel.runModal() == .OK, let url = panel.url {
                saveLocalBookmark(for: url)
                localCurrentDirectory = url
            }
            return
        }
        localCurrentDirectory = URL(fileURLWithPath: path)
    }

    private func saveLocalBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKey.sandboxBookmarkPrefix + url.path)
    }

    private var selectedRemotePaths: [String] {
        // remoteSelectedIDs is kept in sync by RemoteBrowserView (cleaned on hidden-files toggle)
        let selectedFiles = sftpService.files.filter { remoteSelectedIDs.contains($0.id) }
        return selectedFiles.map { file in
            if sftpService.currentPath.hasSuffix("/") {
                return sftpService.currentPath + file.filename
            }
            return sftpService.currentPath + "/" + file.filename
        }
    }
}

