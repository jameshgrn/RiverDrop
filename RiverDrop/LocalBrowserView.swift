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
    @State private var stagedUploads: [StagedItem] = []

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
            PaneHeader("Local", icon: "laptopcomputer", subtitle: localCurrentDirectory.lastPathComponent)
            toolbar
            Divider()
            BreadcrumbView(
                components: pathComponents.map { ($0.name, $0.url) },
                onNavigate: { navigateTo($0) }
            )
            Divider()
            if showContentSearch {
                contentSearchPanel
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
        HStack(spacing: RD.Spacing.xs) {
            // Navigation group
            Button { navigateTo(localCurrentDirectory.deletingLastPathComponent()) } label: {
                Image(systemName: "chevron.left")
            }
            .frame(width: 28, height: 24)
            .help("Go up")
            .disabled(localCurrentDirectory.path == "/")

            Button { loadDirectory() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .frame(width: 28, height: 24)
            .help("Refresh")

            Menu {
                ForEach(Self.bookmarks, id: \.path) { bookmark in
                    Button(bookmark.label) {
                        navigateToBookmark(path: bookmark.path)
                    }
                }
                Divider()
                Button("Choose Folder\u{2026}") {
                    openPanel()
                }
            } label: {
                Image(systemName: "bookmark")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Bookmarks")

            Divider()
                .frame(height: 14)
                .padding(.horizontal, 2)

            // Search group
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                TextField("Filter\u{2026}", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, RD.Spacing.sm)
            .padding(.vertical, RD.Spacing.xs)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: RD.cornerRadiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: RD.cornerRadiusSmall)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .frame(maxWidth: 160)

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
            .frame(width: 28, height: 24)
            .help(RipgrepSearch.isAvailable ? "Content search (rg)" : "ripgrep not installed")
            .disabled(!RipgrepSearch.isAvailable)

            Divider()
                .frame(height: 14)
                .padding(.horizontal, 2)

            Spacer()

            // Actions group
            if !recentlyDownloaded.isEmpty {
                Button { recentlyDownloaded = [] } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.borderless)
                .frame(width: 28, height: 24)
                .help("Clear download highlights")
            }

            if !selectedIDs.isEmpty {
                Button { selectedIDs = [] } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .frame(width: 28, height: 24)
                .help("Deselect all")
            }

            Button { stageSelectedForUpload() } label: {
                Image(systemName: "tray.and.arrow.up")
            }
            .frame(width: 28, height: 24)
            .disabled(selectedFiles.isEmpty || !sftpService.isConnected)
            .help("Stage selected for batch upload")

            Button { uploadSelected() } label: {
                Image(systemName: "arrow.up.circle.fill")
            }
            .frame(width: 28, height: 24)
            .disabled(selectedFiles.isEmpty || !sftpService.isConnected)
            .help(selectedFiles.isEmpty ? "Upload selected" : "Upload \(selectedFiles.count) selected")

            Button { copyLocalPathToClipboard() } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
            .frame(width: 28, height: 24)
            .help("Copy local path")

            Divider()
                .frame(height: 14)
                .padding(.horizontal, 2)

            StatusBadge(
                text: hasMoreFiles
                    ? "\(displayedFiles.count)/\(filteredFiles.count)"
                    : "\(filteredFiles.count) items",
                color: .secondary
            )
        }
        .padding(.horizontal, RD.Spacing.sm)
        .padding(.vertical, RD.Spacing.xs + 1)
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
        VStack(alignment: .leading, spacing: RD.Spacing.sm) {
            HStack(spacing: RD.Spacing.sm) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    TextField("Search file contents\u{2026}", text: $contentSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit { runContentSearch() }
                }
                .padding(.horizontal, RD.Spacing.sm)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: RD.cornerRadiusSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: RD.cornerRadiusSmall)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )

                if ripgrepSearch.isSearching {
                    Button { ripgrepSearch.cancel() } label: {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel search")
                } else {
                    Button { runContentSearch() } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Run search")
                }
            }

            HStack(spacing: RD.Spacing.md) {
                Toggle("Recursive", isOn: $isRecursiveSearch)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                HStack(spacing: RD.Spacing.xs) {
                    Text("Types:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("py,swift,md", text: $fileTypeFilter)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                        .font(.caption)
                }
            }

            if let error = ripgrepSearch.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if ripgrepSearch.isSearching {
                HStack(spacing: RD.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if ripgrepSearch.searchCompleted && ripgrepSearch.results.isEmpty {
                Text("No results found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !ripgrepSearch.results.isEmpty {
                StatusBadge(
                    text: "\(ripgrepSearch.resultCount) match\(ripgrepSearch.resultCount == 1 ? "" : "es")",
                    color: .riverPrimary
                )

                List(ripgrepSearch.results) { result in
                    Button { navigateToResult(result) } label: {
                        HStack(spacing: RD.Spacing.sm) {
                            FileIconView(filename: result.fileName, isDirectory: false, size: 12)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ripgrepSearch.relativePath(for: result))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                HStack(spacing: RD.Spacing.xs) {
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
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
                .frame(maxHeight: 200)
            }
        }
        .padding(.horizontal, RD.Spacing.md)
        .padding(.vertical, RD.Spacing.sm)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
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
        Button { navigateTo(file.url) } label: {
            HStack(spacing: RD.Spacing.sm) {
                FileIconView(filename: file.filename, isDirectory: true)

                Text(file.filename)
                    .lineLimit(1)

                Spacer()

                if let date = file.modificationDate {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.quaternary)
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

                Text(file.filename)
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
