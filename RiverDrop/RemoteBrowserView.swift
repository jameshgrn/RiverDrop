import SwiftUI
import UniformTypeIdentifiers

struct RemoteBrowserView: View {
    @Environment(SFTPService.self) var sftpService
    @Environment(TransferManager.self) var transferManager

    @Binding var remoteSelectedIDs: Set<RemoteFileItem.ID>
    @Binding var localCurrentDirectory: URL
    @Binding var recentlyDownloaded: Set<String>
    @Binding var showDryRunPreview: Bool
    @Binding var dryRunIsUpload: Bool
    @Binding var stagedDownloads: [StagedItem]
    @Binding var stagedUploads: [StagedItem]

    @AppStorage(DefaultsKey.showHiddenRemoteFiles) private var showHiddenRemoteFiles = false

    @State private var remoteRoot = RemoteRoot.home
    @State private var remoteSearchText = ""
    @State private var remoteDisplayLimit = 200
    @State private var showRemoteContentSearch = false
    @State private var remoteContentSearchQuery = ""
    @StateObject private var remoteRipgrepSearch = RemoteRipgrepSearch()
    @State private var showRemoteFileSearch = false
    @State private var remoteFileSearchQuery = ""
    @StateObject private var remoteFileSearch = RemoteFileSearch()
    @State private var remoteSearchDirectories: [String] = UserDefaults.standard.stringArray(forKey: DefaultsKey.remoteSearchDirectories) ?? []
    @State private var hoveredFileID: RemoteFileItem.ID?
    @State private var isRemoteDropTargeted = false
    @State private var searchIndex = DirectorySearchIndex<RemoteFileItem>()
    @State private var searchResults: [RemoteFileItem] = []
    @State private var searchMatchRanges: [RemoteFileItem.ID: [Range<String.Index>]] = [:]
    @State private var searchDebounceTask: Task<Void, Never>?
    @FocusState private var isSearchFieldFocused: Bool

    enum RemoteRoot: String, CaseIterable {
        case home = "Home"
        case notBackedUp = "Scratch"
    }

    // MARK: - Filtered File Lists

    var visibleRemoteFiles: [RemoteFileItem] {
        showHiddenRemoteFiles
            ? sftpService.files
            : sftpService.files.filter { !$0.filename.hasPrefix(".") }
    }

    private var filteredRemoteFiles: [RemoteFileItem] {
        remoteSearchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? visibleRemoteFiles
            : searchResults
    }

    private var displayedRemoteFiles: [RemoteFileItem] {
        Array(filteredRemoteFiles.prefix(remoteDisplayLimit))
    }

    private var hasMoreRemoteFiles: Bool {
        remoteDisplayLimit < filteredRemoteFiles.count
    }

    private var remoteSearchStatusText: String {
        if searchIndex.isSearching {
            return "Searching \(searchIndex.indexedCount) files\u{2026}"
        }
        if !remoteSearchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return "\(filteredRemoteFiles.count) of \(visibleRemoteFiles.count) files"
        }
        if hasMoreRemoteFiles {
            return "\(displayedRemoteFiles.count)/\(filteredRemoteFiles.count)"
        }
        return "\(filteredRemoteFiles.count) items"
    }

    var selectedRemoteFiles: [RemoteFileItem] {
        visibleRemoteFiles.filter { remoteSelectedIDs.contains($0.id) }
    }

    var selectedRemotePaths: [String] {
        selectedRemoteFiles.map { fullRemotePath(for: $0.filename) }
    }

    // MARK: - Body

    var body: some View {
        remotePane
            .sheet(isPresented: $showRemoteFileSearch) {
                SearchDirectoriesSheet(
                    searchDirectories: $remoteSearchDirectories,
                    currentDirectory: sftpService.currentPath
                )
            }
            .sheet(isPresented: $showDryRunPreview) {
            if let result = transferManager.dryRunResult {
                DryRunPreviewView(
                    result: result,
                    isApplying: transferManager.isApplyingSync,
                    onConfirm: {
                        guard !transferManager.isApplyingSync else { return }
                        Task {
                            do {
                                if dryRunIsUpload {
                                    try await transferManager.applySyncUpload(localDir: localCurrentDirectory)
                                } else {
                                    try await transferManager.applySyncDownload(localDir: localCurrentDirectory)
                                }
                                showDryRunPreview = false
                                await sftpService.listDirectory()
                            } catch is CancellationError {
                                // user cancelled, keep sheet open
                            } catch {
                                sftpService.errorMessage = error.localizedDescription
                            }
                        }
                    },
                    onCancel: {
                        showDryRunPreview = false
                    }
                )
            }
        }
        .onChange(of: remoteSearchText) { _, newQuery in
            remoteDisplayLimit = 200
            searchDebounceTask?.cancel()
            let trimmed = newQuery.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                searchResults = []
                searchMatchRanges = [:]
                searchIndex.cancel()
                remoteFileSearch.cancel()
                return
            }
            searchDebounceTask = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                // Recursive find across server dirs (starts async, streams in)
                if sftpService.isConnected {
                    var dirs = [sftpService.currentPath]
                    for dir in remoteSearchDirectories where dir != sftpService.currentPath { dirs.append(dir) }
                    remoteFileSearch.search(query: trimmed, in: dirs, via: sftpService)
                }
                // Fuzzy match current dir (awaited, from cached listing)
                await searchIndex.search(query: trimmed)
                guard !Task.isCancelled else { return }
                searchResults = searchIndex.results.map(\.item)
                searchMatchRanges = Dictionary(
                    uniqueKeysWithValues: searchIndex.results.map { ($0.item.id, $0.matchedRanges) }
                )
            }
        }
        .onChange(of: sftpService.files) { _, _ in
            searchIndex.build(from: visibleRemoteFiles) { $0.filename }
            if !remoteSearchText.trimmingCharacters(in: .whitespaces).isEmpty {
                Task {
                    await searchIndex.search(query: remoteSearchText)
                    searchResults = searchIndex.results.map(\.item)
                    searchMatchRanges = Dictionary(
                        uniqueKeysWithValues: searchIndex.results.map { ($0.item.id, $0.matchedRanges) }
                    )
                }
            }
        }
        .onChange(of: showHiddenRemoteFiles) { _, showHidden in
            if !showHidden {
                let visibleIDs = Set(visibleRemoteFiles.map(\.id))
                remoteSelectedIDs = remoteSelectedIDs.intersection(visibleIDs)
            }
            remoteDisplayLimit = 200
            searchIndex.build(from: visibleRemoteFiles) { $0.filename }
        }
        .onChange(of: remoteSearchDirectories) { _, newDirs in
            UserDefaults.standard.set(newDirs, forKey: DefaultsKey.remoteSearchDirectories)
        }
    }

    // MARK: - Pane Layout

    private var remotePane: some View {
        VStack(spacing: 0) {
            PaneHeader("Remote", icon: "server.rack", subtitle: sftpService.currentPath)
            Divider()
            remoteToolbar
            Divider()
            remotePathBar
            Divider()
            if showRemoteContentSearch { remoteContentSearchPanel; Divider() }
            remoteMainContent
            Divider()
            unifiedStagingArea
        }
        .overlay(
            isRemoteDropTargeted
                ? RoundedRectangle(cornerRadius: RD.cornerRadius)
                    .strokeBorder(Color.green, lineWidth: 2)
                    .background(Color.green.opacity(0.06))
                    .allowsHitTesting(false)
                : nil
        )
        .onDrop(of: [.fileURL], isTargeted: $isRemoteDropTargeted) { providers in
            handleRemoteDrop(providers)
            return true
        }
        .background {
            Button("") { isSearchFieldFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
        .onKeyPress(.escape) {
            if isSearchFieldFocused || !remoteSearchText.isEmpty {
                remoteSearchText = ""
                isSearchFieldFocused = false
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Remote Toolbar

    private var remoteToolbar: some View {
        VStack(spacing: 0) {
            // Main toolbar row
            HStack(spacing: RD.Spacing.sm) {
                // Navigation
                Button {
                    Task { await sftpService.navigateTo("..") }
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .help("Go up")
                .accessibilityLabel("Go to parent directory")
                .disabled(sftpService.currentPath == "/")
                .frame(height: 24)

                Button {
                    Task { await sftpService.listDirectory() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .help("Refresh")
                .accessibilityLabel("Refresh directory listing")
                .frame(height: 24)

                Picker("", selection: $remoteRoot) {
                    ForEach(RemoteRoot.allCases, id: \.self) { root in
                        Text(root.rawValue).tag(root)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .frame(height: 24)
                .onChange(of: remoteRoot) { _, newValue in
                    Task { await navigateRemoteTo(pathForRoot(newValue)) }
                }

                // Filter field — flex width
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption2)
                        .foregroundStyle(isSearchFieldFocused ? Color.accentColor : Color.secondary.opacity(0.3))
                    TextField("Filter\u{2026}", text: $remoteSearchText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .focused($isSearchFieldFocused)
                    if searchIndex.isSearching {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    if !remoteSearchText.isEmpty {
                        Button {
                            remoteSearchText = ""
                            isSearchFieldFocused = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: RD.cornerRadiusSmall))
                .overlay(
                    isSearchFieldFocused
                        ? RoundedRectangle(cornerRadius: RD.cornerRadiusSmall)
                            .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
                        : nil
                )

                // Dry run
                Button {
                    Task {
                        dryRunIsUpload = false
                        await transferManager.runDryRunDownload(localDir: localCurrentDirectory)
                        if transferManager.dryRunResult != nil {
                            showDryRunPreview = true
                        }
                    }
                } label: {
                    if transferManager.isRunningDryRun {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "eye")
                    }
                }
                .frame(width: 28, height: 24)
                .disabled(!RsyncTransfer.isAvailable || !sftpService.isConnected || transferManager.isRunningDryRun)
                .help("Preview rsync changes")
                .accessibilityLabel("Preview rsync changes")

                // Overflow menu
                Menu {
                    Button {
                        showHiddenRemoteFiles.toggle()
                    } label: {
                        Label(
                            showHiddenRemoteFiles ? "Hide Hidden Files" : "Show Hidden Files",
                            systemImage: showHiddenRemoteFiles ? "eye" : "eye.slash"
                        )
                    }

                    Button {
                        showRemoteContentSearch.toggle()
                        if !showRemoteContentSearch {
                            remoteRipgrepSearch.cancel()
                        }
                    } label: {
                        Label("Content Search", systemImage: "doc.text.magnifyingglass")
                    }

                    Button {
                        copyRemotePathToClipboard()
                    } label: {
                        Label("Copy Remote Path", systemImage: "doc.on.clipboard")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.callout)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28, height: 24)
                .help("More actions")
                .accessibilityLabel("More actions")

                StatusBadge(
                    text: remoteSearchStatusText,
                    color: remoteSearchText.isEmpty ? .secondary : .riverPrimary
                )
            }
            .padding(.horizontal, RD.Spacing.sm)
            .padding(.vertical, RD.Spacing.xs + 2)

            // Contextual selection bar
            if !remoteSelectedIDs.isEmpty {
                Divider()
                HStack(spacing: RD.Spacing.sm) {
                    Text("\(selectedRemoteFiles.count) selected")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        stageSelectedFiles()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "tray.and.arrow.down")
                                .font(.caption2)
                            Text("Stage")
                                .font(.caption2.weight(.medium))
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("Stage \(selectedRemoteFiles.count) selected for download")

                    Button {
                        downloadSelectedToLocalDir()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.caption2)
                            Text("Download")
                                .font(.caption2.weight(.medium))
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("Download \(selectedRemoteFiles.count) selected")

                    Button {
                        remoteSelectedIDs = []
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.semibold))
                            Text("Deselect")
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Deselect all")
                }
                .padding(.horizontal, RD.Spacing.sm)
                .padding(.vertical, RD.Spacing.xs + 1)
                .background(Color.accentColor.opacity(0.05))
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.2, dampingFraction: 0.85), value: remoteSelectedIDs.isEmpty)
            }
        }
    }

    // MARK: - Remote Path Bar

    private var remotePathBar: some View {
        BreadcrumbView(
            components: remotePathComponents.map { ($0.name, $0.path) },
            onNavigate: { path in
                Task { await navigateRemoteTo(path) }
            }
        )
    }

    // MARK: - Unified Search Results (Alfred-style)

    @ViewBuilder
    private var remoteMainContent: some View {
        if sftpService.isLoadingDirectory {
            VStack(spacing: RD.Spacing.md) {
                ProgressView().controlSize(.small)
                Text("Loading\u{2026}").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if remoteSearchText.trimmingCharacters(in: .whitespaces).isEmpty {
            if visibleRemoteFiles.isEmpty {
                EmptyStateView("Empty directory", icon: "folder", subtitle: nil)
            } else {
                remoteDirectoryList
            }
        } else {
            remoteUnifiedSearchResults
        }
    }

    private var remoteDirectoryList: some View {
        List {
            ForEach(displayedRemoteFiles) { file in
                if file.isDirectory { remoteFolderRow(file) } else { remoteFileRow(file) }
            }
            if hasMoreRemoteFiles {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Text("Loading more\u{2026}").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .onAppear { remoteDisplayLimit += 200 }
            }
        }
        .listStyle(.inset)
    }

    private var remoteSearchIsActive: Bool { searchIndex.isSearching || remoteFileSearch.isSearching }
    private var remoteSearchHasAny: Bool { !filteredRemoteFiles.isEmpty || !remoteFileSearch.results.isEmpty }

    @ViewBuilder
    private var remoteUnifiedSearchResults: some View {
        if !remoteSearchHasAny && !remoteSearchIsActive {
            VStack(spacing: RD.Spacing.md) {
                Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.tertiary)
                Text("No results for \"\(remoteSearchText)\"")
                    .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Button {
                    showRemoteFileSearch.toggle()
                } label: {
                    Label("Add more search directories", systemImage: "folder.badge.plus")
                        .font(.caption).foregroundColor(.accentColor)
                }
                .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !filteredRemoteFiles.isEmpty {
                    Section("Current folder") {
                        ForEach(filteredRemoteFiles) { file in
                            if file.isDirectory { remoteFolderRow(file) } else { remoteFileRow(file) }
                        }
                    }
                }
                let currentFolderPaths: Set<String> = {
                    let base = sftpService.currentPath.hasSuffix("/")
                        ? sftpService.currentPath
                        : sftpService.currentPath + "/"
                    return Set(filteredRemoteFiles.map { base + $0.filename })
                }()
                let deepResults = remoteFileSearch.results.filter {
                    !currentFolderPaths.contains($0.absolutePath)
                }
                Section {
                    if remoteSearchIsActive && remoteFileSearch.results.isEmpty {
                        HStack(spacing: RD.Spacing.sm) {
                            ProgressView().controlSize(.small)
                            Text("Searching subdirectories\u{2026}")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(deepResults) { result in
                        Button {
                            Task { await navigateRemoteTo(result.directoryPath) }
                        } label: {
                            HStack(spacing: RD.Spacing.sm) {
                                FileIconView(filename: result.filename, isDirectory: result.isDirectory, size: 15)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.filename)
                                        .font(.callout.weight(.medium)).lineLimit(1)
                                    Text(result.relativePath)
                                        .font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    if !deepResults.isEmpty || (remoteSearchIsActive && filteredRemoteFiles.isEmpty) {
                        Text("In subdirectories")
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Content Search Panel

    private var remoteContentSearchPanel: some View {
        VStack(alignment: .leading, spacing: RD.Spacing.sm) {
            HStack(spacing: RD.Spacing.xs) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    TextField("Search file contents...", text: $remoteContentSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .onSubmit {
                            guard !remoteContentSearchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            remoteRipgrepSearch.search(
                                query: remoteContentSearchQuery,
                                in: sftpService.currentPath,
                                via: sftpService
                            )
                        }
                }
                .padding(.horizontal, RD.Spacing.sm)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: RD.cornerRadiusSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: RD.cornerRadiusSmall)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )

                if remoteRipgrepSearch.isSearching {
                    Button {
                        remoteRipgrepSearch.cancel()
                    } label: {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel search")
                    .accessibilityLabel("Cancel search")
                } else {
                    Button {
                        guard !remoteContentSearchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        remoteRipgrepSearch.search(
                            query: remoteContentSearchQuery,
                            in: sftpService.currentPath,
                            via: sftpService
                        )
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("Run search")
                    .accessibilityLabel("Run search")
                }
            }

            HStack(spacing: RD.Spacing.md) {
                HStack(spacing: RD.Spacing.xs) {
                    Text("Max results:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("100", value: $remoteRipgrepSearch.maxCount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .font(.caption)
                        .monospacedDigit()
                }

                HStack(spacing: RD.Spacing.xs) {
                    Text("Max line length:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("200", value: $remoteRipgrepSearch.maxColumns, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .font(.caption)
                        .monospacedDigit()
                }
            }

            if let error = remoteRipgrepSearch.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if remoteRipgrepSearch.isSearching {
                HStack(spacing: RD.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !remoteRipgrepSearch.results.isEmpty {
                StatusBadge(
                    text: "\(remoteRipgrepSearch.results.count) match\(remoteRipgrepSearch.results.count == 1 ? "" : "es")",
                    color: .riverPrimary
                )

                List(remoteRipgrepSearch.results) { result in
                    Button {
                        Task { await navigateRemoteTo(result.directoryPath) }
                    } label: {
                        HStack(spacing: RD.Spacing.sm) {
                            FileIconView(filename: result.filePath, isDirectory: false, size: 12)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.filePath)
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

    // MARK: - Remote File Rows

    private func remoteFolderRow(_ file: RemoteFileItem) -> some View {
        Button {
            Task {
                await sftpService.navigateTo(file.filename)
                remoteSelectedIDs = []
                remoteSearchText = ""
                remoteDisplayLimit = 200
            }
        } label: {
            HStack(spacing: RD.Spacing.sm) {
                FileIconView(filename: file.filename, isDirectory: true, size: 15)

                HighlightedText(text: file.filename, matchedRanges: searchMatchRanges[file.id] ?? [], baseFont: .callout)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer()

                if let date = file.modificationDate {
                    Text(date, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
            .padding(.vertical, 3)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Folder: \(file.filename)")
            .accessibilityHint("Double-tap to open")
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy Remote Path") {
                copyToClipboard(fullRemotePath(for: file.filename))
            }
            Button("Copy SCP Command") {
                copyToClipboard("scp -r \(sftpService.connectedUsername)@\(sftpService.connectedHost):\(fullRemotePath(for: file.filename)) .")
            }
            Button("Copy Rsync Command") {
                copyToClipboard("rsync -avz \(sftpService.connectedUsername)@\(sftpService.connectedHost):\(fullRemotePath(for: file.filename)) .")
            }
        }
    }

    private func remoteFileRow(_ file: RemoteFileItem) -> some View {
        let isSelected = remoteSelectedIDs.contains(file.id)
        let isHovered = hoveredFileID == file.id
        return HStack(spacing: RD.Spacing.sm) {
            FileIconView(filename: file.filename, isDirectory: false, size: 15)

            HighlightedText(text: file.filename, matchedRanges: searchMatchRanges[file.id] ?? [], baseFont: .callout)
                .lineLimit(1)

            Spacer()

            Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)

            if let date = file.modificationDate {
                Text(date, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, RD.Spacing.xs)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.12)
                : isHovered
                    ? Color.accentColor.opacity(0.04)
                    : Color.clear,
            in: RoundedRectangle(cornerRadius: RD.cornerRadiusSmall)
        )
        .animation(.easeOut(duration: 0.08), value: isHovered)
        .animation(.easeOut(duration: 0.08), value: isSelected)
        .onHover { hovering in
            hoveredFileID = hovering ? file.id : nil
        }
        .onDrag {
            remoteDragProvider(for: file)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(file.filename), \(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                if isSelected {
                    remoteSelectedIDs.remove(file.id)
                } else {
                    remoteSelectedIDs.insert(file.id)
                }
            } else {
                remoteSelectedIDs = isSelected ? [] : [file.id]
            }
        }
        .contextMenu {
            Button("Copy Remote Path") {
                copyToClipboard(fullRemotePath(for: file.filename))
            }
            Button("Copy SCP Command") {
                copyToClipboard("scp \(sftpService.connectedUsername)@\(sftpService.connectedHost):\(fullRemotePath(for: file.filename)) .")
            }
            Button("Copy Rsync Command") {
                copyToClipboard("rsync -avz \(sftpService.connectedUsername)@\(sftpService.connectedHost):\(fullRemotePath(for: file.filename)) .")
            }
            Button("Copy SFTP URI") {
                copyToClipboard("sftp://\(sftpService.connectedUsername)@\(sftpService.connectedHost)\(fullRemotePath(for: file.filename))")
            }
            Divider()
            Button("Stage for Download") {
                stageFile(file)
            }
        }
    }

    // MARK: - Unified Staging Area

    private var allStagedItems: [(item: StagedItem, isUpload: Bool)] {
        let uploads = stagedUploads.map { (item: $0, isUpload: true) }
        let downloads = stagedDownloads.map { (item: $0, isUpload: false) }
        return uploads + downloads
    }

    private var unifiedStagingArea: some View {
        Group {
            if stagedUploads.isEmpty && stagedDownloads.isEmpty {
                // Compact empty hint
                HStack(spacing: RD.Spacing.sm) {
                    Image(systemName: "tray")
                        .font(.callout)
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("Drop files to stage transfers")
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: RD.cornerRadiusSmall)
                        .strokeBorder(
                            Color.primary.opacity(0.1),
                            style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                        )
                )
                .padding(.horizontal, RD.Spacing.sm)
                .padding(.vertical, RD.Spacing.sm)
            } else {
                VStack(spacing: 0) {
                    // Header with action buttons
                    HStack(spacing: RD.Spacing.sm) {
                        Image(systemName: "tray.full")
                            .foregroundStyle(Color.riverPrimary)
                            .font(.caption)

                        Text("\(allStagedItems.count) file\(allStagedItems.count == 1 ? "" : "s") staged")
                            .font(.caption2.weight(.medium))

                        Spacer()

                        Button {
                            withAnimation(.easeOut(duration: 0.1)) {
                                stagedUploads.removeAll()
                                stagedDownloads.removeAll()
                            }
                        } label: {
                            Text("Clear")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)

                        if !stagedUploads.isEmpty {
                            Button(action: uploadStaged) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.caption2)
                                    Text("Upload All")
                                        .font(.caption2.weight(.semibold))
                                }
                                .foregroundStyle(.green)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.green.opacity(0.1), in: Capsule())
                                .overlay(Capsule().strokeBorder(.green.opacity(0.2), lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                        }

                        if !stagedDownloads.isEmpty {
                            Button(action: downloadStaged) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.caption2)
                                    Text("Download All")
                                        .font(.caption2.weight(.semibold))
                                }
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.blue.opacity(0.1), in: Capsule())
                                .overlay(Capsule().strokeBorder(.blue.opacity(0.2), lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, RD.Spacing.md)
                    .padding(.top, RD.Spacing.sm)
                    .padding(.bottom, RD.Spacing.xs)

                    // Mixed list of staged items
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: RD.Spacing.xs) {
                            ForEach(allStagedItems, id: \.item.id) { entry in
                                unifiedStagedChip(entry.item, isUpload: entry.isUpload)
                                    .transition(.asymmetric(
                                        insertion: .scale(scale: 0.8).combined(with: .opacity),
                                        removal: .scale(scale: 0.6).combined(with: .opacity)
                                    ))
                            }
                        }
                        .padding(.horizontal, RD.Spacing.md)
                        .padding(.bottom, RD.Spacing.sm)
                        .animation(.spring(response: 0.16, dampingFraction: 0.82), value: allStagedItems.count)
                    }
                }
                .background(Color.riverPrimary.opacity(0.02))
            }
        }
    }

    @ViewBuilder
    private func unifiedStagedChip(_ item: StagedItem, isUpload: Bool) -> some View {
        let chipColor: Color = isUpload ? .green : .blue
        StagedChipView(item: item, chipColor: chipColor, isUpload: isUpload) {
            withAnimation(.spring(response: 0.14, dampingFraction: 0.82)) {
                if isUpload {
                    stagedUploads.removeAll { $0.id == item.id }
                } else {
                    stagedDownloads.removeAll { $0.id == item.id }
                }
            }
        }
    }

    // MARK: - Navigation

    private var remotePathComponents: [(name: String, path: String)] {
        let path = sftpService.currentPath
        guard !path.isEmpty else { return [] }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        var components: [(name: String, path: String)] = [("/", "/")]
        for (i, part) in parts.enumerated() {
            let fullPath = "/" + parts[0...i].joined(separator: "/")
            components.append((String(part), fullPath))
        }
        return components
    }

    func pathForRoot(_ root: RemoteRoot) -> String {
        switch root {
        case .home:
            if !sftpService.homePath.isEmpty {
                return sftpService.homePath
            }
            if !sftpService.currentPath.isEmpty {
                return sftpService.currentPath
            }
            return "."
        case .notBackedUp:
            if sftpService.connectedUsername.isEmpty {
                return "/not_backed_up"
            }
            return "/not_backed_up/\(sftpService.connectedUsername)"
        }
    }

    func navigateRemoteTo(_ path: String) async {
        sftpService.currentPath = path
        await sftpService.listDirectory()
        remoteSelectedIDs = []
        remoteSearchText = ""
        remoteDisplayLimit = 200
    }

    // MARK: - Actions

    private func handleRemoteDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    Task { @MainActor in
                        sftpService.errorMessage = "Drop upload failed: \(error.localizedDescription). Suggested fix: retry dragging the file."
                    }
                    return
                }

                guard let resolved = droppedFileURL(from: item) else {
                    Task { @MainActor in
                        sftpService.errorMessage = "Drop upload failed: unsupported file URL payload. Suggested fix: drag from Finder or the local pane and retry."
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

    private func downloadSelectedToLocalDir() {
        for file in selectedRemoteFiles {
            transferManager.downloadToDirectory(
                remoteFilename: file.filename,
                size: file.size,
                localDir: localCurrentDirectory
            )
        }
        remoteSelectedIDs = []
    }

    private func stageSelectedFiles() {
        for file in selectedRemoteFiles where !file.isDirectory {
            let staged = StagedItem(
                filename: file.filename,
                size: file.size,
                source: .remote(fullRemotePath(for: file.filename))
            )
            stagedDownloads.append(staged)
        }
        remoteSelectedIDs = []
    }

    private func uploadStaged() {
        for item in stagedUploads {
            if case .local(let url) = item.source {
                transferManager.upload(localURL: url)
            }
        }
        stagedUploads = []
    }

    private func downloadStaged() {
        for item in stagedDownloads {
            switch item.source {
            case let .remote(remotePath):
                transferManager.downloadRemotePathToDirectory(
                    remotePath: remotePath,
                    filename: item.filename,
                    size: item.size,
                    localDir: localCurrentDirectory
                )
            case .local:
                break
            }
        }
        stagedDownloads = []
    }

    private func stageFile(_ file: RemoteFileItem) {
        let remotePath = fullRemotePath(for: file.filename)
        withAnimation(.spring(response: 0.16, dampingFraction: 0.82)) {
            stagedDownloads.append(
                StagedItem(filename: file.filename, size: file.size, source: .remote(remotePath))
            )
        }
    }

    private func remoteDragProvider(for file: RemoteFileItem) -> NSItemProvider {
        let payload = RemoteDragPayload(
            remotePath: fullRemotePath(for: file.filename),
            filename: file.filename,
            size: file.size
        )
        let provider = NSItemProvider()

        do {
            let data = try JSONEncoder().encode(payload)
            provider.registerDataRepresentation(
                forTypeIdentifier: RiverDropDragType.remoteFile.identifier,
                visibility: .all
            ) { completion in
                completion(data, nil)
                return nil
            }
        } catch {
            sftpService.errorMessage = "Prepare drag failed for \(file.filename): \(error.localizedDescription). Suggested fix: retry drag from the file list."
        }

        return provider
    }

    func fullRemotePath(for filename: String) -> String {
        if sftpService.currentPath.hasSuffix("/") {
            return sftpService.currentPath + filename
        }
        return sftpService.currentPath + "/" + filename
    }

    // MARK: - Clipboard

    private func copyRemotePathToClipboard() {
        copyToClipboard(sftpService.currentPath)
    }

    private func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
