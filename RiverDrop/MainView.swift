import SwiftUI
import UniformTypeIdentifiers

enum RiverDropDragType {
    static let remoteFile = UTType(exportedAs: "com.riverdrop.remote-file")
}

struct RemoteDragPayload: Codable {
    let remotePath: String
    let filename: String
    let size: UInt64
}

func fuzzyMatch(pattern: String, text: String) -> Int {
    guard !pattern.isEmpty else { return 1 }
    let pattern = pattern.lowercased()
    let text = text.lowercased()

    var patternIdx = pattern.startIndex
    var score = 0
    var lastMatchIndex: String.Index?
    var consecutive = 0

    for textIdx in text.indices {
        guard patternIdx < pattern.endIndex else { break }
        if text[textIdx] == pattern[patternIdx] {
            score += 1

            // Bonus for consecutive matches
            if let last = lastMatchIndex, text.index(after: last) == textIdx {
                consecutive += 1
                score += consecutive
            } else {
                consecutive = 0
            }

            // Bonus for match at start or after separator
            if textIdx == text.startIndex {
                score += 3
            } else {
                let prev = text[text.index(before: textIdx)]
                if prev == "." || prev == "_" || prev == "-" || prev == "/" || prev == " " {
                    score += 2
                }
            }

            lastMatchIndex = textIdx
            patternIdx = pattern.index(after: patternIdx)
        }
    }

    // All pattern characters must be matched
    return patternIdx == pattern.endIndex ? score : 0
}

func fuzzyFilter<T>(items: [T], query: String, getText: (T) -> String) -> [T] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return items }

    let scored = items.map { (item: $0, score: fuzzyMatch(pattern: trimmed, text: getText($0))) }
    let fuzzyHits = scored.filter { $0.score > 0 }
        .sorted { $0.score > $1.score }
        .map(\.item)
    if !fuzzyHits.isEmpty { return fuzzyHits }

    let lower = trimmed.lowercased()
    return items.filter { getText($0).lowercased().contains(lower) }
}

func droppedFileURL(from item: NSSecureCoding?) -> URL? {
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

struct MainView: View {
    @EnvironmentObject var sftpService: SFTPService
    @EnvironmentObject var transferManager: TransferManager
    @EnvironmentObject var storeManager: StoreManager

    @State private var showPaywall = false
    @State private var remoteSelectedIDs: Set<RemoteFileItem.ID> = []
    @State private var localCurrentDirectory = URL(fileURLWithPath: "/Users/\(NSUserName())/projects")
    @State private var remoteRoot = RemoteRoot.home
    @State private var recentlyDownloaded: Set<String> = []
    @State private var isRemoteDropTargeted = false
    @State private var remoteSearchText = ""
    @State private var showDryRunPreview = false
    @AppStorage("alwaysPreviewBeforeSync") private var alwaysPreviewBeforeSync = false
    @State private var remoteDisplayLimit = 200
    @State private var showRemoteContentSearch = false
    @State private var remoteContentSearchQuery = ""
    @StateObject private var remoteRipgrepSearch = RemoteRipgrepSearch()
    @State private var isTransferLogExpanded = false
    @State private var hoveredFileID: RemoteFileItem.ID?
    @State private var stagedDownloads: [StagedItem] = []
    @AppStorage(DefaultsKey.showHiddenRemoteFiles) private var showHiddenRemoteFiles = false
    @State private var stagedUploads: [StagedItem] = []

    private enum RemoteRoot: String, CaseIterable {
        case home = "Home"
        case notBackedUp = "Scratch"
    }

    private var visibleRemoteFiles: [RemoteFileItem] {
        showHiddenRemoteFiles
            ? sftpService.files
            : sftpService.files.filter { !$0.filename.hasPrefix(".") }
    }

    private var filteredRemoteFiles: [RemoteFileItem] {
        fuzzyFilter(items: visibleRemoteFiles, query: remoteSearchText) { $0.filename }
    }

    private var displayedRemoteFiles: [RemoteFileItem] {
        Array(filteredRemoteFiles.prefix(remoteDisplayLimit))
    }

    private var hasMoreRemoteFiles: Bool {
        remoteDisplayLimit < filteredRemoteFiles.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                LocalBrowserView(
                    localCurrentDirectory: $localCurrentDirectory,
                    recentlyDownloaded: $recentlyDownloaded
                )
                .frame(minWidth: 250)

                remoteBrowser
                    .frame(minWidth: 350)
            }
            Divider()
            transferLog
            Divider()
            connectionFooter
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
            transferManager.onDownloadCompleted = { filename in
                recentlyDownloaded.insert(filename)
            }
            Task { await navigateRemoteTo(pathForRoot(remoteRoot)) }
        }
        .onChange(of: showHiddenRemoteFiles) { _, showHidden in
            if !showHidden {
                let visibleIDs = Set(visibleRemoteFiles.map(\.id))
                remoteSelectedIDs = remoteSelectedIDs.intersection(visibleIDs)
            }
            remoteDisplayLimit = 200
        }
    }

    // MARK: - Remote Browser

    private var remoteBrowser: some View {
        VStack(spacing: 0) {
            PaneHeader("Remote", icon: "server.rack", subtitle: sftpService.currentPath)
            Divider()
            remoteToolbar
            Divider()
            remotePathBar
            Divider()

            if showRemoteContentSearch {
                remoteContentSearchPanel
                Divider()
            }

            if filteredRemoteFiles.isEmpty {
                EmptyStateView(
                    remoteSearchText.isEmpty ? "Empty directory" : "No matches",
                    icon: remoteSearchText.isEmpty ? "folder" : "magnifyingglass",
                    subtitle: remoteSearchText.isEmpty ? nil : "Try a different search term"
                )
            } else {
                List {
                    ForEach(displayedRemoteFiles) { file in
                        if file.isDirectory {
                            remoteFolderRow(file)
                        } else {
                            remoteFileRow(file)
                        }
                    }
                    if hasMoreRemoteFiles {
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
                            remoteDisplayLimit += 200
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            Divider()
            DropZoneView(
                direction: .upload,
                stagedItems: $stagedUploads,
                onTransferAll: uploadStaged
            )
            DropZoneView(
                direction: .download,
                stagedItems: $stagedDownloads,
                onTransferAll: downloadStaged
            )
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
        .sheet(isPresented: $showDryRunPreview) {
            if let result = transferManager.dryRunResult {
                DryRunPreviewView(
                    result: result,
                    onConfirm: {
                        showDryRunPreview = false
                        if storeManager.isPro {
                            transferManager.syncDirectory(localDir: localCurrentDirectory)
                        } else {
                            showPaywall = true
                        }
                    },
                    onCancel: {
                        showDryRunPreview = false
                    }
                )
            }
        }
        .onChange(of: remoteSearchText) { _, _ in
            remoteDisplayLimit = 200
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
    }

    // MARK: - Remote Toolbar

    private var remoteToolbar: some View {
        HStack(spacing: RD.Spacing.xs) {
            // Navigation group
            Group {
                Button {
                    Task { await sftpService.navigateTo("..") }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Go up")
                .disabled(sftpService.currentPath == "/")

                Button {
                    Task { await sftpService.listDirectory() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")

                Button {
                    showHiddenRemoteFiles.toggle()
                } label: {
                    Image(systemName: showHiddenRemoteFiles ? "eye" : "eye.slash")
                }
                .help(showHiddenRemoteFiles ? "Hide hidden files" : "Show hidden files")

                Picker("", selection: $remoteRoot) {
                    ForEach(RemoteRoot.allCases, id: \.self) { root in
                        Text(root.rawValue).tag(root)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: remoteRoot) { _, newValue in
                    Task { await navigateRemoteTo(pathForRoot(newValue)) }
                }
            }
            .frame(height: 24)

            Divider()
                .frame(height: 16)

            // Search
            HStack(spacing: 2) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                TextField("Filter...", text: $remoteSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !remoteSearchText.isEmpty {
                    Button {
                        remoteSearchText = ""
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
            .frame(maxWidth: 150)

            Button {
                if storeManager.isPro {
                    showRemoteContentSearch.toggle()
                    if !showRemoteContentSearch {
                        remoteRipgrepSearch.cancel()
                    }
                } else {
                    showPaywall = true
                }
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .frame(width: 28, height: 24)
            .help("Remote content search (rg)")

            Spacer()

            // Actions group
            if !remoteSelectedIDs.isEmpty {
                Button {
                    stageSelectedFiles()
                } label: {
                    Image(systemName: "tray.and.arrow.down")
                }
                .frame(width: 28, height: 24)
                .help("Stage \(selectedRemoteFiles.count) selected for download")

                Button {
                    remoteSelectedIDs = []
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .frame(width: 28, height: 24)
                .help("Deselect all")
            }

            Button {
                downloadSelectedToLocalDir()
            } label: {
                Image(systemName: "arrow.down.circle.fill")
            }
            .frame(width: 28, height: 24)
            .disabled(selectedRemoteFiles.isEmpty)
            .help(selectedRemoteFiles.isEmpty ? "Download selected" : "Download \(selectedRemoteFiles.count) selected")

            Button {
                copyRemotePathToClipboard()
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
            .frame(width: 28, height: 24)
            .help("Copy remote path")

            Button {
                if storeManager.isPro {
                    Task {
                        await transferManager.runDryRunDownload(localDir: localCurrentDirectory)
                        if transferManager.dryRunResult != nil {
                            showDryRunPreview = true
                        }
                    }
                } else {
                    showPaywall = true
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

            Divider()
                .frame(height: 16)

            StatusBadge(
                text: hasMoreRemoteFiles
                    ? "\(displayedRemoteFiles.count)/\(filteredRemoteFiles.count)"
                    : "\(filteredRemoteFiles.count) items",
                color: .secondary
            )
        }
        .padding(.horizontal, RD.Spacing.sm)
        .padding(.vertical, RD.Spacing.xs + 2)
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

    // MARK: - Content Search Panel

    private var remoteContentSearchPanel: some View {
        VStack(alignment: .leading, spacing: RD.Spacing.sm) {
            HStack(spacing: RD.Spacing.xs) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    TextField("Search file contents...", text: $remoteContentSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
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
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Run search")
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

    private func pathForRoot(_ root: RemoteRoot) -> String {
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

    private func navigateRemoteTo(_ path: String) async {
        sftpService.currentPath = path
        await sftpService.listDirectory()
        remoteSelectedIDs = []
        remoteSearchText = ""
        remoteDisplayLimit = 200
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

                Text(file.filename)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Spacer()

                if let date = file.modificationDate {
                    Text(date, style: .date)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
            }
            .padding(.vertical, 1)
        }
        .buttonStyle(.plain)
    }

    private func remoteFileRow(_ file: RemoteFileItem) -> some View {
        let isSelected = remoteSelectedIDs.contains(file.id)
        let isHovered = hoveredFileID == file.id
        return HStack(spacing: RD.Spacing.sm) {
            FileIconView(filename: file.filename, isDirectory: false, size: 15)

            Text(file.filename)
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer()

            Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)

            if let date = file.modificationDate {
                Text(date, style: .date)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 1)
        .padding(.horizontal, isSelected || isHovered ? RD.Spacing.xs : 0)
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
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected {
                remoteSelectedIDs.remove(file.id)
            } else {
                remoteSelectedIDs.insert(file.id)
            }
        }
    }

    // MARK: - Transfer Log

    private var transferSummary: String {
        let transfers = transferManager.transfers
        guard !transfers.isEmpty else { return "No transfers" }
        let active = transfers.filter { $0.status == .inProgress }.count
        let completed = transfers.filter { $0.status == .completed }.count
        let failed = transfers.filter { $0.status == .failed }.count
        let cancelled = transfers.filter { $0.status == .cancelled }.count
        var parts: [String] = []
        if active > 0 { parts.append("\(active) active") }
        if completed > 0 { parts.append("\(completed) done") }
        if failed > 0 { parts.append("\(failed) failed") }
        if cancelled > 0 { parts.append("\(cancelled) cancelled") }
        return parts.isEmpty ? "No transfers" : parts.joined(separator: ", ")
    }

    private var hasActiveTransfers: Bool {
        transferManager.transfers.contains { $0.status == .inProgress }
    }

    private var transferLog: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: RD.Spacing.sm) {
                Button {
                    withAnimation(.spring(response: 0.16, dampingFraction: 0.85)) {
                        isTransferLogExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isTransferLogExpanded ? 90 : 0))
                        .animation(.spring(response: 0.16, dampingFraction: 0.85), value: isTransferLogExpanded)
                        .frame(width: 14)
                }
                .buttonStyle(.borderless)

                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.riverPrimary)

                Text("Transfers")
                    .font(.system(size: 12, weight: .semibold))

                StatusBadge(text: transferSummary, color: hasActiveTransfers ? .riverAccent : .secondary)

                Spacer()

                if hasActiveTransfers {
                    ProgressView()
                        .controlSize(.mini)
                }

                if !transferManager.transfers.isEmpty {
                    Button {
                        transferManager.transfers.removeAll(where: { $0.status != .inProgress })
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear completed transfers")
                }
            }
            .padding(.horizontal, RD.Spacing.md)
            .padding(.vertical, RD.Spacing.sm)

            if isTransferLogExpanded && !transferManager.transfers.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(spacing: RD.Spacing.xs) {
                        ForEach(transferManager.transfers) { item in
                            transferRow(item)
                        }
                    }
                    .padding(RD.Spacing.sm)
                }
                .frame(minHeight: 60, maxHeight: 150)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onChange(of: hasActiveTransfers) { _, active in
            if active {
                withAnimation(.easeInOut(duration: 0.12)) {
                    isTransferLogExpanded = true
                }
            }
        }
    }

    private func transferRow(_ item: TransferItem) -> some View {
        HStack(spacing: RD.Spacing.sm) {
            Image(systemName: item.isUpload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(item.isUpload ? .green : .blue)

            Text(item.filename)
                .lineLimit(1)
                .font(.system(size: 12))

            Spacer()

            if item.status == .inProgress {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 80, height: 5)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.riverPrimary, .riverAccent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, 80 * item.progress), height: 5)
                        .shadow(color: .riverAccent.opacity(0.3), radius: 3)
                        .animation(.easeOut(duration: 0.12), value: item.progress)
                }
                .frame(width: 80)

                Text("\(Int(item.progress * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)

                Button {
                    transferManager.cancelTransfer(id: item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.borderless)
                .help("Cancel transfer")
            } else {
                transferStatusView(item)
            }
        }
        .padding(.horizontal, RD.Spacing.sm)
        .padding(.vertical, RD.Spacing.xs)
        .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: RD.cornerRadiusSmall))
    }

    private var connectionFooter: some View {
        HStack(spacing: RD.Spacing.sm) {
            Image(systemName: sftpService.isConnected ? "lock.shield.fill" : "lock.slash")
                .font(.system(size: 11))
                .foregroundStyle(sftpService.isConnected ? Color.riverPrimary : .secondary)

            Text(sftpService.isConnected ? "\(sftpService.connectedUsername)@\(sftpService.connectedHost)" : "Not connected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            StatusBadge(text: sftpService.connectionMethodLabel, color: .riverPrimary)
            StatusBadge(text: "Auth: \(sftpService.authenticationMethodLabel)", color: .secondary)
        }
        .padding(.horizontal, RD.Spacing.md)
        .padding(.vertical, RD.Spacing.xs + 2)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    @ViewBuilder
    private func transferStatusView(_ item: TransferItem) -> some View {
        switch item.status {
        case .completed:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                StatusBadge(text: "Done", color: .green)
                if !item.destinationDirectory.isEmpty {
                    Button {
                        if item.isUpload {
                            Task { await navigateRemoteTo(item.destinationDirectory) }
                        } else {
                            localCurrentDirectory = URL(fileURLWithPath: item.destinationDirectory)
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.right.circle")
                                .font(.system(size: 10))
                            Text("Show")
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(.blue)
                    }
                    .buttonStyle(.borderless)
                    .help(item.isUpload ? "Navigate to remote directory" : "Navigate to local directory")
                }
            }
        case .failed:
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                StatusBadge(text: "Failed", color: .red)
            }
        case .cancelled:
            HStack(spacing: 4) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                StatusBadge(text: "Cancelled", color: .orange)
            }
        case .skipped:
            StatusBadge(text: "Skipped", color: .secondary)
        case .inProgress:
            EmptyView()
        }
    }

    // MARK: - Actions

    private var selectedRemoteFiles: [RemoteFileItem] {
        visibleRemoteFiles.filter { remoteSelectedIDs.contains($0.id) }
    }

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

    private func fullRemotePath(for filename: String) -> String {
        if sftpService.currentPath.hasSuffix("/") {
            return sftpService.currentPath + filename
        }
        return sftpService.currentPath + "/" + filename
    }

    // MARK: - Clipboard

    private func copyRemotePathToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sftpService.currentPath, forType: .string)
    }
}
