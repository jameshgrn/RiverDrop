import SwiftUI
import UniformTypeIdentifiers

struct LocalBrowserView: View {
    @Environment(TransferManager.self) var transferManager
    @Environment(SFTPService.self) var sftpService
    @Binding var localCurrentDirectory: URL
    @Binding var recentlyDownloaded: Set<String>
    @Binding var showDryRunPreview: Bool
    @Binding var dryRunIsUpload: Bool
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
    @State private var showDeleteConfirmation = false
    @State private var itemToDelete: LocalFileItem?
    @State private var showTrashConfirmation = false
    @State private var showRenameAlert = false
    @State private var itemToRename: LocalFileItem?
    @State private var renameText = ""
    @Binding var stagedUploads: [StagedItem]
    @AppStorage(DefaultsKey.showHiddenLocalFiles) private var showHiddenFiles = false
    @State private var savedBookmarks: [SavedBookmark] = []
    @State private var searchIndex = DirectorySearchIndex<LocalFileItem>()
    @State private var searchResults: [LocalFileItem] = []
    @State private var searchMatchRanges: [LocalFileItem.ID: [Range<String.Index>]] = [:]
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var loadDirectoryTask: Task<Void, Never>?
    @FocusState private var isSearchFieldFocused: Bool

    private var filteredFiles: [LocalFileItem] {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? files
            : searchResults
    }

    private var displayedFiles: [LocalFileItem] {
        Array(filteredFiles.prefix(localDisplayLimit))
    }

    private var hasMoreFiles: Bool {
        localDisplayLimit < filteredFiles.count
    }

    private var localSearchStatusText: String {
        if searchIndex.isSearching {
            return "Searching \(searchIndex.indexedCount) files\u{2026}"
        }
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return "\(filteredFiles.count) of \(files.count) files"
        }
        if hasMoreFiles {
            return "\(displayedFiles.count)/\(filteredFiles.count)"
        }
        return "\(filteredFiles.count) items"
    }

    private var selectedFiles: [LocalFileItem] {
        files.filter { selectedIDs.contains($0.id) }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader("Local", icon: "laptopcomputer", subtitle: localCurrentDirectory.lastPathComponent)
            LocalToolbarView(
                currentDirectory: localCurrentDirectory,
                isAtRoot: localCurrentDirectory.path == "/",
                isConnected: sftpService.isConnected,
                isRunningDryRun: transferManager.isRunningDryRun,
                filteredCount: filteredFiles.count,
                displayedCount: displayedFiles.count,
                hasMoreFiles: hasMoreFiles,
                selectedCount: selectedIDs.count,
                recentlyDownloadedCount: recentlyDownloaded.count,
                searchText: $searchText,
                showHiddenFiles: $showHiddenFiles,
                savedBookmarks: $savedBookmarks,
                isSearchFieldFocused: $isSearchFieldFocused,
                searchStatusText: localSearchStatusText,
                isSearching: searchIndex.isSearching,
                onGoUp: { navigateTo(localCurrentDirectory.deletingLastPathComponent()) },
                onRefresh: { loadDirectory() },
                onNavigateToBookmark: { navigateToBookmark(path: $0) },
                onSaveCurrentBookmark: { saveCurrentFolderAsBookmark() },
                onRemoveBookmark: { removeBookmark($0) },
                onChooseFolder: { openPanel() },
                onDryRun: {
                    Task {
                        dryRunIsUpload = true
                        await transferManager.runDryRunUpload(localDir: localCurrentDirectory)
                        if transferManager.dryRunResult != nil {
                            showDryRunPreview = true
                        }
                    }
                },
                onToggleContentSearch: {
                    showContentSearch.toggle()
                    if !showContentSearch { ripgrepSearch.cancel() }
                },
                onCopyPath: { LocalFileOperations.copyDirectoryPath(localCurrentDirectory) },
                onClearDownloadHighlights: { recentlyDownloaded = [] },
                onStageSelected: { stageSelectedForUpload() },
                onUploadSelected: { uploadSelected() },
                onDeselectAll: { selectedIDs = [] }
            )
            Divider()
            BreadcrumbView(
                components: pathComponents.map { ($0.name, $0.url) },
                onNavigate: { navigateTo($0) }
            )
            Divider()
            if showContentSearch {
                ContentSearchPanel(
                    ripgrepSearch: ripgrepSearch,
                    contentSearchQuery: $contentSearchQuery,
                    isRecursiveSearch: $isRecursiveSearch,
                    fileTypeFilter: $fileTypeFilter,
                    onSearch: { runContentSearch() },
                    onNavigateToResult: { navigateToResult($0) }
                )
                Divider()
            }
            fileList
            Divider()
            DropZoneView(direction: .upload, stagedItems: $stagedUploads, onTransferAll: uploadStaged)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: RD.cornerRadius)
                    .fill(Color.green.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: RD.cornerRadius)
                            .strokeBorder(Color.green.opacity(0.4), lineWidth: 1.5)
                    )
                    .shadow(color: Color.green.opacity(0.15), radius: 8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, RiverDropDragType.remoteFile], isTargeted: $isDropTargeted) { providers in
            handleLocalDrop(providers)
            return true
        }
        .onAppear {
            savedBookmarks = BookmarkManager.load()
            if !hasRequestedAccess {
                hasRequestedAccess = true
                requestInitialAccess()
            }
        }
        .onChange(of: recentlyDownloaded) { _, _ in
            loadDirectory()
        }
        .onChange(of: searchText) { _, newQuery in
            localDisplayLimit = 200
            searchDebounceTask?.cancel()
            let trimmed = newQuery.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                searchResults = []
                searchMatchRanges = [:]
                searchIndex.cancel()
                return
            }
            searchDebounceTask = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                await searchIndex.search(query: trimmed)
                guard !Task.isCancelled else { return }
                searchResults = searchIndex.results.map(\.item)
                searchMatchRanges = Dictionary(
                    uniqueKeysWithValues: searchIndex.results.map { ($0.item.id, $0.matchedRanges) }
                )
            }
        }
        .onChange(of: showHiddenFiles) { _, _ in
            selectedIDs = []
            localDisplayLimit = 200
            loadDirectory()
        }
        .background {
            Button("") { isSearchFieldFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onKeyPress(.escape) {
            if isSearchFieldFocused || !searchText.isEmpty {
                searchText = ""
                isSearchFieldFocused = false
                return .handled
            }
            return .ignored
        }
        .onDisappear {
            stopSecurityScopedAccess()
        }
        .alert("Delete Permanently?", isPresented: $showDeleteConfirmation, presenting: itemToDelete) { file in
            Button("Delete", role: .destructive) {
                if let err = LocalFileOperations.permanentlyDelete(file) {
                    sftpService.errorMessage = err
                }
                selectedIDs.remove(file.id)
                loadDirectory()
            }
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
                if let file = itemToRename {
                    if let err = LocalFileOperations.rename(file, to: renameText) {
                        sftpService.errorMessage = err
                    }
                    loadDirectory()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a new name:")
        }
    }

    // MARK: - File List

    private var fileList: some View {
        Group {
            if filteredFiles.isEmpty {
                if searchText.isEmpty {
                    EmptyStateView("Empty directory", icon: "folder", subtitle: "No files in this location")
                } else {
                    EmptyStateView("No matches", icon: "magnifyingglass", subtitle: "Try a different search term")
                }
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
                            Text("Loading more\u{2026}")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .onAppear {
                            localDisplayLimit += 200
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onKeyPress(.return) {
            guard !selectedIDs.isEmpty else { return .ignored }
            for file in selectedFiles {
                LocalFileOperations.openFile(file) { navigateTo($0) }
            }
            return .handled
        }
        .onKeyPress(.delete) {
            guard !selectedIDs.isEmpty else { return .ignored }
            showTrashConfirmation = true
            return .handled
        }
    }

    private func folderRow(_ file: LocalFileItem) -> some View {
        Button { navigateTo(file.url) } label: {
            HStack(spacing: RD.Spacing.sm) {
                FileIconView(filename: file.filename, isDirectory: true)

                HighlightedText(text: file.filename, matchedRanges: searchMatchRanges[file.id] ?? [], baseFont: .body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer()

                if let date = file.modificationDate {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Folder: \(file.filename)")
            .accessibilityHint("Double-tap to open")
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open in Finder") {
                NSWorkspace.shared.open(file.url)
            }
            Button("Copy Path") {
                LocalFileOperations.copyItemPath(file)
            }
            Divider()
            Button("Rename\u{2026}") {
                itemToRename = file
                renameText = file.filename
                showRenameAlert = true
            }
            Button("Move to Trash") {
                if let err = LocalFileOperations.moveToTrash(file) {
                    sftpService.errorMessage = err
                }
                selectedIDs.remove(file.id)
                loadDirectory()
            }
        }
    }

    private func fileRow(_ file: LocalFileItem) -> some View {
        let isSelected = selectedIDs.contains(file.id)
        let isNew = recentlyDownloaded.contains(file.filename)
        let isHighlighted = highlightFileName == file.filename

        return HStack(spacing: 0) {
            if isNew {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(
                        LinearGradient(
                            colors: [.green, .green.opacity(0.6)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3)
                    .padding(.vertical, 2)
                    .padding(.trailing, RD.Spacing.sm)
                    .shadow(color: .green.opacity(0.3), radius: 3)
            }

            HStack(spacing: RD.Spacing.sm) {
                FileIconView(filename: file.filename, isDirectory: false)

                HighlightedText(text: file.filename, matchedRanges: searchMatchRanges[file.id] ?? [], baseFont: .body)
                    .lineLimit(1)

                if isNew {
                    StatusBadge(text: "New", color: .green)
                }

                Spacer()

                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()

                if let date = file.modificationDate {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 60, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 2)
        .onDrag {
            NSItemProvider(object: file.url as NSURL)
        }
        .listRowBackground(
            isSelected
                ? Color.accentColor.opacity(0.12)
                : isHighlighted
                    ? Color.riverPrimary.opacity(0.06)
                    : nil
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(file.filename), \(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            LocalFileOperations.openFile(file) { navigateTo($0) }
        }
        .onTapGesture(count: 1) {
            highlightFileName = nil
            if NSEvent.modifierFlags.contains(.command) {
                if isSelected {
                    selectedIDs.remove(file.id)
                } else {
                    selectedIDs.insert(file.id)
                }
            } else {
                selectedIDs = isSelected ? [] : [file.id]
            }
        }
        .contextMenu {
            Button("Open") { LocalFileOperations.openFile(file) { navigateTo($0) } }
            openWithMenu(for: file)
            Divider()
            Button("Show in Finder") { LocalFileOperations.showInFinder(file) }
            Button("Copy Path") { LocalFileOperations.copyItemPath(file) }
            Divider()
            Button("Move to Trash") {
                if let err = LocalFileOperations.moveToTrash(file) {
                    sftpService.errorMessage = err
                }
                selectedIDs.remove(file.id)
                loadDirectory()
            }
            Button("Delete\u{2026}") {
                itemToDelete = file
                showDeleteConfirmation = true
            }
        }
    }

    @ViewBuilder
    private func openWithMenu(for file: LocalFileItem) -> some View {
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: file.url)
        if apps.isEmpty {
            Button("Open With\u{2026}") { LocalFileOperations.openFile(file) { navigateTo($0) } }
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

    // MARK: - Bookmarks

    private func saveCurrentFolderAsBookmark() {
        BookmarkManager.add(
            label: localCurrentDirectory.lastPathComponent,
            path: localCurrentDirectory.path,
            to: &savedBookmarks
        )
    }

    private func removeBookmark(_ bookmark: SavedBookmark) {
        BookmarkManager.remove(bookmark, from: &savedBookmarks)
    }

    // MARK: - Content Search

    private func runContentSearch() {
        let query = contentSearchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        let types = fileTypeFilter
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        ripgrepSearch.search(
            query: query,
            in: localCurrentDirectory,
            recursive: isRecursiveSearch,
            fileTypes: types,
            securityScopedURL: activeSecurityScopedURL
        )
    }

    private func navigateToResult(_ result: RipgrepResult) {
        navigateTo(result.directoryURL)
        highlightFileName = result.fileName
    }

    // MARK: - Staging

    private func stageSelectedForUpload() {
        for file in selectedFiles {
            stagedUploads.append(
                StagedItem(filename: file.filename, size: file.size, source: .local(file.url))
            )
        }
        selectedIDs = []
    }

    private func uploadStaged() {
        for item in stagedUploads {
            if case .local(let url) = item.source {
                transferManager.upload(localURL: url)
            }
        }
        stagedUploads = []
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

        Task {
            guard let granted = await promptForAccess(directoryURL: url, message: "Grant access to \(url.lastPathComponent)") else { return }
            guard beginSecurityScopedAccess(to: granted) else {
                sftpService.errorMessage = "Open directory failed for \(granted.path): could not start security-scoped access. Suggested fix: re-select the folder from the bookmark menu."
                return
            }
            saveBookmark(url: granted, key: path)
            navigateTo(granted)
        }
    }

    private func openPanel() {
        Task {
            guard let url = await promptForAccess(directoryURL: nil, message: nil) else { return }
            guard beginSecurityScopedAccess(to: url) else {
                sftpService.errorMessage = "Open directory failed for \(url.path): could not start security-scoped access. Suggested fix: re-select the folder and grant access again."
                return
            }
            saveBookmark(url: url, key: url.path)
            navigateTo(url)
        }
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
        Task {
            if let url = await promptForAccess(directoryURL: startDir, message: "Select folder to grant file access") {
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

    private func promptForAccess(directoryURL: URL?, message: String?) async -> URL? {
        let panel = NSOpenPanel()
        if let dir = directoryURL { panel.directoryURL = dir }
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let msg = message { panel.message = msg }
        panel.prompt = "Open"

        if let window = NSApp.keyWindow {
            let response = await panel.beginSheetModal(for: window)
            guard response == .OK, let url = panel.url else { return nil }
            return url
        } else {
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            return url
        }
    }

    // MARK: - File Loading

    private func loadDirectory() {
        loadDirectoryTask?.cancel()
        let dir = localCurrentDirectory
        let hidden = showHiddenFiles
        let downloaded = recentlyDownloaded

        loadDirectoryTask = Task {
            let result: (items: [LocalFileItem], error: String?)
            result = await Task.detached {
                do {
                    let urls = try FileManager.default.contentsOfDirectory(
                        at: dir,
                        includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                        options: hidden ? [] : [.skipsHiddenFiles]
                    )
                    var skippedCount = 0
                    let items = urls.compactMap { url -> LocalFileItem? in
                        let originalValues: URLResourceValues
                        do {
                            originalValues = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
                        } catch {
                            skippedCount += 1
                            return nil
                        }
                        let isSymlink = originalValues.isSymbolicLink ?? false
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
                            isSymbolicLink: isSymlink,
                            size: UInt64(values.fileSize ?? 0),
                            modificationDate: values.contentModificationDate,
                            url: url,
                            resolvedURL: resolved
                        )
                    }
                    .sorted { lhs, rhs in
                        let lhsNew = downloaded.contains(lhs.filename)
                        let rhsNew = downloaded.contains(rhs.filename)
                        if lhsNew != rhsNew { return lhsNew }
                        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                        return lhs.filename.localizedCaseInsensitiveCompare(rhs.filename) == .orderedAscending
                    }
                    let err: String? = skippedCount > 0
                        ? "List local directory partially failed for \(dir.path): skipped \(skippedCount) item(s). Suggested fix: check local permissions and retry."
                        : nil
                    return (items, err)
                } catch {
                    return ([], "List local directory failed for \(dir.path): \(error.localizedDescription). Suggested fix: check local permissions and confirm the folder still exists.")
                }
            }.value

            guard !Task.isCancelled else { return }
            files = result.items
            if let error = result.error {
                sftpService.errorMessage = error
            }
            searchIndex.build(from: files) { $0.filename }
        }
    }

    // MARK: - Upload / Selection Actions

    private func uploadSelected() {
        for file in selectedFiles {
            transferManager.upload(localURL: file.url)
        }
        selectedIDs = []
    }

    private func trashSelectedFiles() {
        let errors = LocalFileOperations.trashFiles(selectedFiles)
        for err in errors {
            sftpService.errorMessage = err
        }
        selectedIDs = []
        loadDirectory()
    }

    // MARK: - Drop Handling

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
                    let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path)
                    let size = (attrs?[.size] as? UInt64) ?? 0
                    withAnimation(.spring(response: 0.16, dampingFraction: 0.82)) {
                        stagedUploads.append(
                            StagedItem(filename: resolved.lastPathComponent, size: size, source: .local(resolved))
                        )
                    }
                }
            }
        }
    }
}
