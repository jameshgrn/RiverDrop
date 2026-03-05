import SwiftUI

/// The toolbar for the local browser pane: navigation, bookmarks, filter, dry-run, overflow menu.
struct LocalToolbarView: View {
    // MARK: - Inputs

    let currentDirectory: URL
    let isAtRoot: Bool
    let isConnected: Bool
    let isRunningDryRun: Bool
    let filteredCount: Int
    let displayedCount: Int
    let hasMoreFiles: Bool
    let selectedCount: Int
    let recentlyDownloadedCount: Int

    @Binding var searchText: String
    @Binding var showHiddenFiles: Bool
    @Binding var savedBookmarks: [SavedBookmark]

    // MARK: - Actions

    var onGoUp: () -> Void
    var onRefresh: () -> Void
    var onNavigateToBookmark: (String) -> Void
    var onSaveCurrentBookmark: () -> Void
    var onRemoveBookmark: (SavedBookmark) -> Void
    var onChooseFolder: () -> Void
    var onDryRun: () -> Void
    var onToggleContentSearch: () -> Void
    var onCopyPath: () -> Void
    var onClearDownloadHighlights: () -> Void

    // Selection bar actions
    var onStageSelected: () -> Void
    var onUploadSelected: () -> Void
    var onDeselectAll: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            mainRow
            if selectedCount > 0 {
                Divider()
                selectionBar
            }
        }
    }

    // MARK: - Main Row

    private var mainRow: some View {
        HStack(spacing: RD.Spacing.sm) {
            // Left: navigation + bookmarks
            Button { onGoUp() } label: {
                Image(systemName: "chevron.left")
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .frame(width: 28, height: 24)
            .help("Go up")
            .accessibilityLabel("Go to parent directory")
            .disabled(isAtRoot)

            Button { onRefresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .frame(width: 28, height: 24)
            .help("Refresh")
            .accessibilityLabel("Refresh directory listing")

            bookmarksMenu

            filterField

            dryRunButton

            overflowMenu

            StatusBadge(
                text: hasMoreFiles
                    ? "\(displayedCount)/\(filteredCount)"
                    : "\(filteredCount) items",
                color: .secondary
            )
        }
        .padding(.horizontal, RD.Spacing.sm)
        .padding(.vertical, RD.Spacing.xs + 1)
    }

    // MARK: - Bookmarks Menu

    private var bookmarksMenu: some View {
        Menu {
            ForEach(BookmarkManager.defaultBookmarks, id: \.path) { bookmark in
                if FileManager.default.fileExists(atPath: bookmark.path) {
                    Button(bookmark.label) {
                        onNavigateToBookmark(bookmark.path)
                    }
                }
            }

            if !savedBookmarks.isEmpty {
                Divider()
                ForEach(savedBookmarks, id: \.path) { bookmark in
                    Button(bookmark.label) {
                        onNavigateToBookmark(bookmark.path)
                    }
                }
            }

            Divider()

            Button("Save Current Folder") {
                onSaveCurrentBookmark()
            }
            .disabled(BookmarkManager.isBookmarked(path: currentDirectory.path, in: savedBookmarks))

            Button("Choose Folder\u{2026}") {
                onChooseFolder()
            }

            if !savedBookmarks.isEmpty {
                Divider()
                Menu("Remove Bookmark") {
                    ForEach(savedBookmarks, id: \.path) { bookmark in
                        Button(bookmark.label) {
                            onRemoveBookmark(bookmark)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "bookmark")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Bookmarks")
        .accessibilityLabel("Bookmarks")
    }

    // MARK: - Filter Field

    private var filterField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            TextField("Filter\u{2026}", text: $searchText)
                .textFieldStyle(.plain)
                .font(.caption)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
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
    }

    // MARK: - Dry Run Button

    private var dryRunButton: some View {
        Button {
            onDryRun()
        } label: {
            if isRunningDryRun {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "eye")
            }
        }
        .frame(width: 28, height: 24)
        .disabled(!RsyncTransfer.isAvailable || !isConnected || isRunningDryRun)
        .help("Preview rsync upload changes")
        .accessibilityLabel("Preview rsync upload changes")
    }

    // MARK: - Overflow Menu

    private var overflowMenu: some View {
        Menu {
            Button {
                showHiddenFiles.toggle()
            } label: {
                Label(
                    showHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files",
                    systemImage: showHiddenFiles ? "eye" : "eye.slash"
                )
            }

            Button {
                onToggleContentSearch()
            } label: {
                Label("Content Search", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(!RipgrepSearch.isAvailable)

            Button { onCopyPath() } label: {
                Label("Copy Local Path", systemImage: "doc.on.clipboard")
            }

            if recentlyDownloadedCount > 0 {
                Button { onClearDownloadHighlights() } label: {
                    Label("Clear Download Highlights", systemImage: "sparkles")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions")
    }

    // MARK: - Selection Bar

    private var selectionBar: some View {
        HStack(spacing: RD.Spacing.sm) {
            Text("\(selectedCount) selected")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer()

            Button { onStageSelected() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "tray.and.arrow.up")
                        .font(.caption2)
                    Text("Stage")
                        .font(.caption2.weight(.medium))
                }
            }
            .buttonStyle(.borderless)
            .disabled(!isConnected)
            .help("Stage selected for batch upload")

            Button { onUploadSelected() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.caption2)
                    Text("Upload")
                        .font(.caption2.weight(.medium))
                }
            }
            .buttonStyle(.borderless)
            .disabled(!isConnected)
            .help("Upload \(selectedCount) selected")

            Button { onDeselectAll() } label: {
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
        .animation(.spring(response: 0.2, dampingFraction: 0.85), value: selectedCount == 0)
    }
}
