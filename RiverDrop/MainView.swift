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

struct MainView: View {
    @EnvironmentObject var sftpService: SFTPService
    @EnvironmentObject var transferManager: TransferManager

    @State private var remoteSelectedIDs: Set<RemoteFileItem.ID> = []
    @State private var localCurrentDirectory = URL(fileURLWithPath: "/Users/\(NSUserName())/projects")
    @State private var remoteRoot = RemoteRoot.home
    @State private var recentlyDownloaded: Set<String> = []
    @State private var isRemoteDropTargeted = false
    @State private var remoteSearchText = ""

    private enum RemoteRoot: String, CaseIterable {
        case home = "Home"
        case notBackedUp = "Scratch"
    }

    private var filteredRemoteFiles: [RemoteFileItem] {
        let query = remoteSearchText.trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return sftpService.files }

        let scored = sftpService.files
            .map { (file: $0, score: fuzzyMatch(pattern: query, text: $0.filename)) }

        let fuzzyHits = scored.filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .map(\.file)
        if !fuzzyHits.isEmpty { return fuzzyHits }

        // Fallback: substring match so the list never goes blank unexpectedly
        let lower = query.lowercased()
        let substringHits = sftpService.files
            .filter { $0.filename.lowercased().contains(lower) }
        return substringHits
    }

    var body: some View {
        VSplitView {
            HSplitView {
                LocalBrowserView(
                    localCurrentDirectory: $localCurrentDirectory,
                    recentlyDownloaded: $recentlyDownloaded
                )
                .frame(minWidth: 250)
                remoteBrowser
                    .frame(minWidth: 350)
            }
            transferLog
                .frame(minHeight: 100, idealHeight: 150)
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
    }

    // MARK: - Remote Browser

    private var remoteBrowser: some View {
        VStack(spacing: 0) {
            remoteToolbar
            Divider()
            remotePathBar
            Divider()

            if filteredRemoteFiles.isEmpty {
                if remoteSearchText.isEmpty {
                    ContentUnavailableView("Empty Directory", systemImage: "folder")
                } else {
                    ContentUnavailableView("No matches", systemImage: "magnifyingglass")
                }
            } else {
                List {
                    ForEach(filteredRemoteFiles) { file in
                        if file.isDirectory {
                            remoteFolderRow(file)
                        } else {
                            remoteFileRow(file)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .overlay(
            isRemoteDropTargeted
                ? RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.green, lineWidth: 2)
                    .background(Color.green.opacity(0.08))
                    .allowsHitTesting(false)
                : nil
        )
        .onDrop(of: [.fileURL], isTargeted: $isRemoteDropTargeted) { providers in
            handleRemoteDrop(providers)
            return true
        }
    }

    private var remoteToolbar: some View {
        HStack {
            Button {
                Task { await sftpService.navigateTo("..") }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(sftpService.currentPath == "/")

            Button {
                Task { await sftpService.listDirectory() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }

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

            TextField("Filter...", text: $remoteSearchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 140)

            Spacer()

            if !remoteSelectedIDs.isEmpty {
                Button("Deselect All") {
                    remoteSelectedIDs = []
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            Button {
                downloadSelectedToLocalDir()
            } label: {
                Label("Download \(selectedRemoteFiles.count > 0 ? "(\(selectedRemoteFiles.count))" : "")",
                      systemImage: "arrow.down.circle.fill")
            }
            .disabled(selectedRemoteFiles.isEmpty)

            Text("\(filteredRemoteFiles.count) items")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var remotePathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(remotePathComponents, id: \.path) { component in
                    Button(component.name) {
                        Task { await navigateRemoteTo(component.path) }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)

                    if component.path != sftpService.currentPath {
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
    }

    private func remoteFolderRow(_ file: RemoteFileItem) -> some View {
        Button {
            Task { await sftpService.navigateTo(file.filename) }
            remoteSelectedIDs = []
            remoteSearchText = ""
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

    private func remoteFileRow(_ file: RemoteFileItem) -> some View {
        let isSelected = remoteSelectedIDs.contains(file.id)
        return HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

            Image(systemName: "doc.fill")
                .foregroundStyle(.secondary)

            Text(file.filename)
                .lineLimit(1)

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

    private var transferLog: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers")
                    .font(.headline)
                Spacer()
                if !transferManager.transfers.isEmpty {
                    Button("Clear") {
                        transferManager.transfers.removeAll(where: { $0.status != .inProgress })
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            if transferManager.transfers.isEmpty {
                ContentUnavailableView("No transfers", systemImage: "arrow.up.arrow.down")
                    .frame(maxWidth: .infinity)
            } else {
                List(transferManager.transfers) { item in
                    HStack {
                        Image(systemName: item.isUpload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(item.isUpload ? .green : .blue)
                        Text(item.filename)
                            .lineLimit(1)
                        Spacer()
                        if item.status == .inProgress {
                            ProgressView(value: item.progress)
                                .frame(width: 100)
                            Text("\(Int(item.progress * 100))%")
                                .font(.caption)
                                .monospacedDigit()
                                .frame(width: 36, alignment: .trailing)
                            Button {
                                transferManager.cancelTransfer(id: item.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Cancel transfer")
                        } else {
                            Text(item.status.rawValue)
                                .font(.caption)
                                .foregroundStyle(transferStatusColor(for: item.status))
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Actions

    private var selectedRemoteFiles: [RemoteFileItem] {
        sftpService.files.filter { remoteSelectedIDs.contains($0.id) }
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

    private func transferStatusColor(for status: TransferItem.TransferStatus) -> Color {
        switch status {
        case .completed:
            return .green
        case .failed:
            return .red
        case .skipped:
            return .secondary
        case .inProgress:
            return .primary
        case .cancelled:
            return .orange
        }
    }
}
