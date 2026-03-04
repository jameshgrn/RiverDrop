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

    private static let bookmarks: [(label: String, path: String)] = [
        ("Projects", "/Users/\(NSUserName())/projects"),
        ("Home", "/Users/\(NSUserName())"),
        ("Cluster Scratch", "/not_backed_up/\(NSUserName())"),
    ]

    private var filteredFiles: [LocalFileItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return files }

        let scored = files
            .map { (file: $0, score: fuzzyMatch(pattern: query, text: $0.filename)) }

        let fuzzyHits = scored.filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .map(\.file)
        if !fuzzyHits.isEmpty { return fuzzyHits }

        // Fallback: substring match so the list never goes blank unexpectedly
        let lower = query.lowercased()
        let substringHits = files
            .filter { $0.filename.lowercased().contains(lower) }
        return substringHits
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
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            Button {
                navigateTo(localCurrentDirectory.deletingLastPathComponent())
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(localCurrentDirectory.path == "/")

            Button { loadDirectory() } label: {
                Image(systemName: "arrow.clockwise")
            }

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

            if !recentlyDownloaded.isEmpty {
                Button("Clear Highlights") {
                    recentlyDownloaded = []
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            if !selectedIDs.isEmpty {
                Button("Deselect All") {
                    selectedIDs = []
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            Button { uploadSelected() } label: {
                Label("Upload \(selectedFiles.count > 0 ? "(\(selectedFiles.count))" : "")",
                      systemImage: "arrow.up.circle.fill")
            }
            .disabled(selectedFiles.isEmpty || !sftpService.isConnected)

            Button {
                copyLocalPathToClipboard()
            } label: {
                Label("Copy Path", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("Copy current directory path to clipboard")

            Text(hasMoreFiles
                ? "Showing \(displayedFiles.count) of \(filteredFiles.count)"
                : "\(filteredFiles.count) items")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                if searchText.isEmpty {
                    ContentUnavailableView("Empty Directory", systemImage: "folder")
                } else {
                    ContentUnavailableView("No matches", systemImage: "magnifyingglass")
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
        .onTapGesture {
            highlightFileName = nil
            if isSelected {
                selectedIDs.remove(file.id)
            } else {
                selectedIDs.insert(file.id)
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

    private static let bookmarkDefaultsPrefix = "SandboxBookmark_"

    private func saveBookmark(url: URL, key: String) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: Self.bookmarkDefaultsPrefix + key)
        } catch {
            sftpService.errorMessage = "Save bookmark failed for \(url.path): \(error.localizedDescription). Suggested fix: re-select the folder and try again."
        }
    }

    private func restoreSavedBookmark(for key: String) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkDefaultsPrefix + key) else {
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

    private func droppedFileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url.standardizedFileURL
        }
        if let nsURL = item as? NSURL {
            return (nsURL as URL).standardizedFileURL
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)?.standardizedFileURL
        }
        if let string = item as? String,
           let url = URL(string: string),
           url.isFileURL
        {
            return url.standardizedFileURL
        }
        return nil
    }

    // MARK: - Clipboard

    private func copyLocalPathToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(localCurrentDirectory.path, forType: .string)
    }
}
