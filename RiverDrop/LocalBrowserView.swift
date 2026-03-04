import SwiftUI
import UniformTypeIdentifiers

struct LocalBrowserView: View {
    @EnvironmentObject var transferManager: TransferManager
    @EnvironmentObject var sftpService: SFTPService
    @EnvironmentObject var storeManager: StoreManager

    @Binding var localCurrentDirectory: URL
    @Binding var recentlyDownloaded: Set<String>
    @State private var files: [LocalFileItem] = []
    @State private var selectedIDs: Set<LocalFileItem.ID> = []
    @State private var isDropTargeted = false
    @State private var hasRequestedAccess = false
    @State private var activeSecurityScopedURL: URL?
    @State private var searchText = ""
    @State private var localDisplayLimit = 200
    @State private var showContentSearch = false
    @State private var contentSearchQuery = ""
    @State private var isRecursiveSearch = true
    @State private var fileTypeFilter = ""
    @State private var highlightFileName: String?
    @StateObject private var ripgrepSearch = RipgrepSearch()
    @State private var showPaywall = false
    @State private var showDeleteConfirmation = false
    @State private var itemToDelete: LocalFileItem?
    @State private var showTrashConfirmation = false
    @State private var showRenameAlert = false
    @State private var itemToRename: LocalFileItem?
    @State private var renameText = ""

    private static let bookmarks: [(label: String, path: String)] = [
        ("Projects", "/Users/\(NSUserName())/projects"),
        ("Home", "/Users/\(NSUserName())"),
        ("Cluster Scratch", "/not_backed_up/\(NSUserName())"),
    ]

    private var filteredFiles: [LocalFileItem] {
        fuzzyFilter(items: files, query: searchText) { $0.filename }
    }

    private var displayedFiles: [LocalFileItem] {
        Array(filteredFiles.prefix(localDisplayLimit))
    }

    private var hasMoreFiles: Bool {
        localDisplayLimit < filteredFiles.count
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            pathBar
            Divider()
            if showContentSearch {
                contentSearchPanel
                Divider()
            }
            fileList
        }
        .overlay(
            isDropTargeted
                ? RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.08))
                    .allowsHitTesting(false)
                : nil
        )
        .onDrop(of: [.fileURL, RiverDropDragType.remoteFile], isTargeted: $isDropTargeted) { providers in
            handleLocalDrop(providers)
            return true
        }
        .onAppear {
            if !hasRequestedAccess {
                hasRequestedAccess = true
                requestInitialAccess()
            }
        }
        .onChange(of: recentlyDownloaded) { _, _ in
            loadDirectory()
        }
        .onChange(of: searchText) { _, _ in
            localDisplayLimit = 200
        }
        .onDisappear {
            stopSecurityScopedAccess()
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .alert("Delete Permanently?", isPresented: $showDeleteConfirmation, presenting: itemToDelete) { file in
            Button("Delete", role: .destructive) { permanentlyDelete(file) }
            Button("Cancel", role: .cancel) { }
        } message: { file in
            Text("\"\(file.filename)\" will be permanently deleted. This cannot be undone.")
        }
        .alert("Move to Trash?", isPresented: $showTrashConfirmation) {
            Button("Move to Trash", role: .destructive) { trashSelectedFiles() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("\(selectedIDs.count) item(s) will be moved to the Trash.")
        }
        .alert("Rename", isPresented: $showRenameAlert) {
            TextField("New name", text: $renameText)
            Button("Rename") {
                if let file = itemToRename { performRename(file) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a new name:")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            // Navigation group
            Button {
                navigateTo(localCurrentDirectory.deletingLastPathComponent())
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("Go up")
            .disabled(localCurrentDirectory.path == "/")

            Button { loadDirectory() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")

            Menu {
                ForEach(Self.bookmarks, id: \.path) { bookmark in
                    Button(bookmark.label) {
                        navigateToBookmark(path: bookmark.path)
                    }
                }
                Divider()
                Button("Choose Folder...") {
                    openPanel()
                }
            } label: {
                Image(systemName: "bookmark")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Bookmarks")

            Divider()
                .frame(height: 16)

            // Search group
            TextField("Filter...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 140)

            Button {
                if storeManager.isPro {
                    showContentSearch.toggle()
                    if !showContentSearch {
                        ripgrepSearch.cancel()
                    }
                } else {
                    showPaywall = true
                }
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .help(RipgrepSearch.isAvailable ? "Content search (rg)" : "ripgrep not installed")
            .disabled(!RipgrepSearch.isAvailable)

            Spacer()

            // Actions group
            if !recentlyDownloaded.isEmpty {
                Button {
                    recentlyDownloaded = []
                } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.borderless)
                .help("Clear download highlights")
            }

            if !selectedIDs.isEmpty {
                Button {
                    selectedIDs = []
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Deselect all")
            }

            Button { uploadSelected() } label: {
                Image(systemName: "arrow.up.circle.fill")
            }
            .disabled(selectedFiles.isEmpty || !sftpService.isConnected)
            .help(selectedFiles.isEmpty ? "Upload selected" : "Upload \(selectedFiles.count) selected")

            Button {
                copyLocalPathToClipboard()
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
            .help("Copy local path")

            Divider()
                .frame(height: 16)

            Text(hasMoreFiles
                ? "\(displayedFiles.count)/\(filteredFiles.count)"
                : "\(filteredFiles.count) items")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Content Search Panel

    private var parsedFileTypes: [String] {
        fileTypeFilter
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func runContentSearch() {
        let query = contentSearchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        ripgrepSearch.search(
            query: query,
            in: localCurrentDirectory,
            recursive: isRecursiveSearch,
            fileTypes: parsedFileTypes,
            securityScopedURL: activeSecurityScopedURL
        )
    }

    private func navigateToResult(_ result: RipgrepResult) {
        navigateTo(result.directoryURL)
        highlightFileName = result.fileName
    }

    private var contentSearchPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Search file contents...", text: $contentSearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runContentSearch() }

                if ripgrepSearch.isSearching {
                    Button {
                        ripgrepSearch.cancel()
                    } label: {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel search")
                } else {
                    Button { runContentSearch() } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            HStack(spacing: 12) {
                Toggle("Recursive", isOn: $isRecursiveSearch)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                HStack(spacing: 4) {
                    Text("Types:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("py,swift,md", text: $fileTypeFilter)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 8)

            if let error = ripgrepSearch.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
            }

            if ripgrepSearch.isSearching {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
            } else if ripgrepSearch.searchCompleted && ripgrepSearch.results.isEmpty {
                Text("No results found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }

            if !ripgrepSearch.results.isEmpty {
                HStack {
                    Text("\(ripgrepSearch.resultCount) match\(ripgrepSearch.resultCount == 1 ? "" : "es")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)

                List(ripgrepSearch.results) { result in
                    Button {
                        navigateToResult(result)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ripgrepSearch.relativePath(for: result))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack(spacing: 4) {
                                Text("L\(result.lineNumber)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                                Text(result.content)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
                .frame(maxHeight: 200)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Path Bar

    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(pathComponents, id: \.url) { component in
                    Button(component.name) {
                        navigateTo(component.url)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)

                    if component.url != localCurrentDirectory {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - File List

    private var fileList: some View {
        Group {
            if filteredFiles.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: searchText.isEmpty ? "folder" : "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(searchText.isEmpty ? "Empty directory" : "No matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(displayedFiles) { file in
                        if file.isDirectory {
                            folderRow(file)
                        } else {
                            fileRow(file)
                        }
                    }
                    if hasMoreFiles {
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading more...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .onAppear {
                            localDisplayLimit += 200
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onKeyPress(.return) {
            guard !selectedIDs.isEmpty else { return .ignored }
            openSelectedFiles()
            return .handled
        }
        .onKeyPress(.delete) {
            guard !selectedIDs.isEmpty else { return .ignored }
            showTrashConfirmation = true
            return .handled
        }
    }

    private func folderRow(_ file: LocalFileItem) -> some View {
        Button {
            navigateTo(file.url)
        } label: {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.blue)
                Text(file.filename)
                    .lineLimit(1)
                Spacer()
                if let date = file.modificationDate {
                    Text(date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open in Finder") {
                NSWorkspace.shared.open(file.url)
            }
            Button("Copy Path") {
                copyItemPath(file)
            }
            Divider()
            Button("Rename\u{2026}") {
                itemToRename = file
                renameText = file.filename
                showRenameAlert = true
            }
            Button("Move to Trash") {
                moveToTrash(file)
            }
        }
    }

    private func fileRow(_ file: LocalFileItem) -> some View {
        let isSelected = selectedIDs.contains(file.id)
        let isNew = recentlyDownloaded.contains(file.filename)
        let isHighlighted = highlightFileName == file.filename
        return HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

            Image(systemName: "doc.fill")
                .foregroundStyle(isNew ? .green : .secondary)

            Text(file.filename)
                .lineLimit(1)
                .foregroundStyle(isNew ? .green : .primary)
                .fontWeight(isNew ? .semibold : .regular)

            if isNew {
                Text("NEW")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.green, in: Capsule())
            }

            Spacer()

            Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let date = file.modificationDate {
                Text(date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDrag {
            NSItemProvider(object: file.url as NSURL)
        }
        .listRowBackground(isHighlighted ? Color.accentColor.opacity(0.15) : nil)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            openFile(file)
        }
        .onTapGesture(count: 1) {
            highlightFileName = nil
            if isSelected {
                selectedIDs.remove(file.id)
            } else {
                selectedIDs.insert(file.id)
            }
        }
        .contextMenu {
            Button("Open") { openFile(file) }
            openWithMenu(for: file)
            Divider()
            Button("Show in Finder") { showInFinder(file) }
            Button("Copy Path") { copyItemPath(file) }
            Divider()
            Button("Move to Trash") { moveToTrash(file) }
            Button("Delete\u{2026}") {
                itemToDelete = file
                showDeleteConfirmation = true
            }
        }
    }

    // MARK: - Navigation

    private var pathComponents: [(name: String, url: URL)] {
        var result: [(name: String, url: URL)] = []
        var url = localCurrentDirectory.standardizedFileURL
        while url.path != "/" {
            result.insert((url.lastPathComponent, url), at: 0)
            url = url.deletingLastPathComponent()
        }
        result.insert(("/", URL(fileURLWithPath: "/")), at: 0)
        return result
    }

    private func navigateTo(_ url: URL) {
        localCurrentDirectory = url.standardizedFileURL
        selectedIDs = []
        recentlyDownloaded = []
        searchText = ""
        highlightFileName = nil
        localDisplayLimit = 200
        loadDirectory()
    }

    private func navigateToBookmark(path: String) {
        let url = URL(fileURLWithPath: path)
        if restoreSavedBookmark(for: path) { return }
        if FileManager.default.isReadableFile(atPath: path) {
            stopSecurityScopedAccess()
            saveBookmark(url: url, key: path)
            navigateTo(url)
            return
        }

        guard let granted = promptForAccess(directoryURL: url, message: "Grant access to \(url.lastPathComponent)") else { return }
        guard beginSecurityScopedAccess(to: granted) else {
            sftpService.errorMessage = "Open directory failed for \(granted.path): could not start security-scoped access. Suggested fix: re-select the folder from the bookmark menu."
            return
        }
        saveBookmark(url: granted, key: path)
        navigateTo(granted)
    }

    private func openPanel() {
        guard let url = promptForAccess(directoryURL: nil, message: nil) else { return }
        guard beginSecurityScopedAccess(to: url) else {
            sftpService.errorMessage = "Open directory failed for \(url.path): could not start security-scoped access. Suggested fix: re-select the folder and grant access again."
            return
        }
        saveBookmark(url: url, key: url.path)
        navigateTo(url)
    }

    private func requestInitialAccess() {
        let startDir = localCurrentDirectory
        if restoreSavedBookmark(for: startDir.path) { return }
        if FileManager.default.isReadableFile(atPath: startDir.path) {
            stopSecurityScopedAccess()
            saveBookmark(url: startDir, key: startDir.path)
            loadDirectory()
            return
        }
        if let url = promptForAccess(directoryURL: startDir, message: "Select folder to grant file access") {
            guard beginSecurityScopedAccess(to: url) else {
                sftpService.errorMessage = "Open directory failed for \(url.path): could not start security-scoped access. Suggested fix: re-select the folder and grant access again."
                loadDirectory()
                return
            }
            saveBookmark(url: url, key: url.path)
            navigateTo(url)
        } else {
            loadDirectory()
        }
    }

    // MARK: - Security-Scoped Bookmarks

    private func saveBookmark(url: URL, key: String) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: DefaultsKey.sandboxBookmarkPrefix + key)
        } catch {
            sftpService.errorMessage = "Save bookmark failed for \(url.path): \(error.localizedDescription). Suggested fix: re-select the folder and try again."
        }
    }

    private func restoreSavedBookmark(for key: String) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.sandboxBookmarkPrefix + key) else {
            return false
        }

        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            sftpService.errorMessage = "Restore bookmark failed for key \(key): \(error.localizedDescription). Suggested fix: remove and recreate the bookmark from the folder picker."
            return false
        }

        guard beginSecurityScopedAccess(to: url) else {
            sftpService.errorMessage = "Restore bookmark failed for \(url.path): could not start security-scoped access. Suggested fix: re-select the folder from the bookmark menu."
            return false
        }
        if isStale { saveBookmark(url: url, key: key) }
        navigateTo(url)
        return true
    }

    private func beginSecurityScopedAccess(to url: URL) -> Bool {
        if activeSecurityScopedURL?.standardizedFileURL == url.standardizedFileURL {
            return true
        }

        stopSecurityScopedAccess()
        guard url.startAccessingSecurityScopedResource() else { return false }
        activeSecurityScopedURL = url
        return true
    }

    private func stopSecurityScopedAccess() {
        if let activeSecurityScopedURL {
            activeSecurityScopedURL.stopAccessingSecurityScopedResource()
            self.activeSecurityScopedURL = nil
        }
    }

    private func promptForAccess(directoryURL: URL?, message: String?) -> URL? {
        let panel = NSOpenPanel()
        if let dir = directoryURL { panel.directoryURL = dir }
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let msg = message { panel.message = msg }
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    // MARK: - File Loading

    private func loadDirectory() {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: localCurrentDirectory,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            var skippedCount = 0
            files = urls.compactMap { url in
                let resolved = url.resolvingSymlinksInPath()
                let values: URLResourceValues
                do {
                    values = try resolved.resourceValues(
                        forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
                    )
                } catch {
                    skippedCount += 1
                    return nil
                }
                return LocalFileItem(
                    filename: url.lastPathComponent,
                    isDirectory: values.isDirectory ?? false,
                    size: UInt64(values.fileSize ?? 0),
                    modificationDate: values.contentModificationDate,
                    url: resolved
                )
            }
            .sorted { lhs, rhs in
                let lhsNew = recentlyDownloaded.contains(lhs.filename)
                let rhsNew = recentlyDownloaded.contains(rhs.filename)
                if lhsNew != rhsNew { return lhsNew }
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.filename.localizedCaseInsensitiveCompare(rhs.filename) == .orderedAscending
            }
            if skippedCount > 0 {
                sftpService.errorMessage = "List local directory partially failed for \(localCurrentDirectory.path): skipped \(skippedCount) item(s). Suggested fix: check local permissions and retry."
            }
        } catch {
            files = []
            sftpService.errorMessage = "List local directory failed for \(localCurrentDirectory.path): \(error.localizedDescription). Suggested fix: check local permissions and confirm the folder still exists."
        }
    }

    // MARK: - Actions

    private var selectedFiles: [LocalFileItem] {
        files.filter { selectedIDs.contains($0.id) }
    }

    private func uploadSelected() {
        for file in selectedFiles {
            transferManager.upload(localURL: file.url)
        }
        selectedIDs = []
    }

    private func handleLocalDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(RiverDropDragType.remoteFile.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: RiverDropDragType.remoteFile.identifier) { data, error in
                    if let error {
                        Task { @MainActor in
                            sftpService.errorMessage = "Drop download failed: \(error.localizedDescription). Suggested fix: retry dragging from the remote pane."
                        }
                        return
                    }

                    guard let data else {
                        Task { @MainActor in
                            sftpService.errorMessage = "Drop download failed: missing remote file payload. Suggested fix: retry dragging from the remote pane."
                        }
                        return
                    }

                    let payload: RemoteDragPayload
                    do {
                        payload = try JSONDecoder().decode(RemoteDragPayload.self, from: data)
                    } catch {
                        Task { @MainActor in
                            sftpService.errorMessage = "Drop download failed: invalid remote file payload (\(error.localizedDescription)). Suggested fix: retry dragging from the remote pane."
                        }
                        return
                    }

                    Task { @MainActor in
                        transferManager.downloadRemotePathToDirectory(
                            remotePath: payload.remotePath,
                            filename: payload.filename,
                            size: payload.size,
                            localDir: localCurrentDirectory
                        )
                    }
                }
                continue
            }

            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                continue
            }

            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    Task { @MainActor in
                        sftpService.errorMessage = "Drop upload failed: \(error.localizedDescription). Suggested fix: retry dragging the file."
                    }
                    return
                }

                guard let resolved = droppedFileURL(from: item) else {
                    Task { @MainActor in
                        sftpService.errorMessage = "Drop upload failed: unsupported file URL payload. Suggested fix: drag a local file and retry."
                    }
                    return
                }

                Task { @MainActor in
                    transferManager.upload(localURL: resolved)
                }
            }
        }
    }

    // MARK: - File Operations

    private func openFile(_ file: LocalFileItem) {
        if file.isDirectory {
            navigateTo(file.url)
        } else {
            NSWorkspace.shared.open(file.url)
        }
    }

    private func openSelectedFiles() {
        for file in selectedFiles {
            openFile(file)
        }
    }

    @ViewBuilder
    private func openWithMenu(for file: LocalFileItem) -> some View {
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: file.url)
        if apps.isEmpty {
            Button("Open With\u{2026}") { openFile(file) }
                .disabled(true)
        } else {
            Menu("Open With") {
                ForEach(Array(apps.prefix(15)), id: \.self) { appURL in
                    Button(appURL.deletingPathExtension().lastPathComponent) {
                        Task {
                            let config = NSWorkspace.OpenConfiguration()
                            _ = try? await NSWorkspace.shared.open(
                                [file.url], withApplicationAt: appURL, configuration: config
                            )
                        }
                    }
                }
            }
        }
    }

    private func showInFinder(_ file: LocalFileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    private func copyItemPath(_ file: LocalFileItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(file.url.path, forType: .string)
    }

    private func moveToTrash(_ file: LocalFileItem) {
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            selectedIDs.remove(file.id)
            loadDirectory()
        } catch {
            sftpService.errorMessage = "Move to Trash failed for \(file.filename): \(error.localizedDescription). Suggested fix: check file permissions."
        }
    }

    private func trashSelectedFiles() {
        for file in selectedFiles {
            do {
                try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            } catch {
                sftpService.errorMessage = "Move to Trash failed for \(file.filename): \(error.localizedDescription). Suggested fix: check file permissions."
            }
        }
        selectedIDs = []
        loadDirectory()
    }

    private func permanentlyDelete(_ file: LocalFileItem) {
        do {
            try FileManager.default.removeItem(at: file.url)
            selectedIDs.remove(file.id)
            loadDirectory()
        } catch {
            sftpService.errorMessage = "Delete failed for \(file.filename): \(error.localizedDescription). Suggested fix: check file permissions."
        }
    }

    private func performRename(_ file: LocalFileItem) {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != file.filename else { return }
        let newURL = file.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            try FileManager.default.moveItem(at: file.url, to: newURL)
            loadDirectory()
        } catch {
            sftpService.errorMessage = "Rename failed for \(file.filename): \(error.localizedDescription). Suggested fix: check permissions and ensure name is valid."
        }
    }

    // MARK: - Clipboard

    private func copyLocalPathToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(localCurrentDirectory.path, forType: .string)
    }
}
