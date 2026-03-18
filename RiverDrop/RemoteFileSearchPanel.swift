import SwiftUI

struct RemoteFileSearchPanel: View {
    @ObservedObject var search: RemoteFileSearch
    @Binding var query: String
    @Binding var searchDirectories: [String]

    let currentDirectory: String
    let sftpService: SFTPService
    var onNavigate: (String) -> Void

    @State private var isEditingDirs = false
    @State private var newDirPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: RD.Spacing.sm) {
            searchField
            directorySection
            statusSection
            resultsSection
        }
        .padding(.horizontal, RD.Spacing.md)
        .padding(.vertical, RD.Spacing.sm)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: RD.Spacing.sm) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                TextField("Find files\u{2026}", text: $query)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .onSubmit { runSearch() }
            }
            .padding(.horizontal, RD.Spacing.sm)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: RD.cornerRadiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: RD.cornerRadiusSmall)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )

            if search.isSearching {
                Button { search.cancel() } label: {
                    Image(systemName: "stop.fill").foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Cancel")
            } else {
                Button { runSearch() } label: {
                    Image(systemName: "play.fill").font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Search")
            }
        }
    }

    // MARK: - Directory Chips

    private var directorySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: RD.Spacing.xs) {
                Text("Search in:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    isEditingDirs.toggle()
                } label: {
                    Image(systemName: isEditingDirs ? "checkmark.circle.fill" : "pencil.circle")
                        .font(.caption)
                        .foregroundStyle(isEditingDirs ? .green : .secondary)
                }
                .buttonStyle(.borderless)
                .help(isEditingDirs ? "Done" : "Edit search directories")
            }

            FlowLayout(spacing: 4) {
                directoryChip(abbreviate(currentDirectory), removable: false)

                ForEach(searchDirectories, id: \.self) { dir in
                    directoryChip(abbreviate(dir), removable: isEditingDirs) {
                        searchDirectories.removeAll { $0 == dir }
                    }
                }

                if isEditingDirs {
                    addDirectoryField
                }
            }
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        if let error = search.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundColor(search.results.isEmpty ? .secondary : .red)
        }

        if search.isSearching {
            HStack(spacing: RD.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Searching\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        if !search.results.isEmpty {
            StatusBadge(
                text: "\(search.results.count) file\(search.results.count == 1 ? "" : "s")",
                color: .riverPrimary
            )

            List(search.results) { result in
                Button { onNavigate(result.directoryPath) } label: {
                    HStack(spacing: RD.Spacing.sm) {
                        FileIconView(filename: result.filename, isDirectory: result.isDirectory, size: 12)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.filename)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Text(result.relativePath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
            .frame(maxHeight: 240)
        }
    }

    // MARK: - Helpers

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var dirs = [currentDirectory]
        for dir in searchDirectories where dir != currentDirectory {
            dirs.append(dir)
        }
        search.search(query: trimmed, in: dirs, via: sftpService)
    }

    private func directoryChip(_ text: String, removable: Bool, onRemove: (() -> Void)? = nil) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "folder").font(.system(size: 8))
            Text(text).font(.caption2).lineLimit(1)
            if removable, let onRemove {
                Button { onRemove() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private var addDirectoryField: some View {
        HStack(spacing: 3) {
            Image(systemName: "plus").font(.system(size: 8))
            TextField("/path/to/dir", text: $newDirPath)
                .textFieldStyle(.plain)
                .font(.caption2)
                .frame(width: 120)
                .onSubmit {
                    let path = newDirPath.trimmingCharacters(in: .whitespaces)
                    guard !path.isEmpty, !searchDirectories.contains(path) else { return }
                    searchDirectories.append(path)
                    newDirPath = ""
                }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.04), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }

    private func abbreviate(_ path: String) -> String {
        if let range = path.range(of: "/home/") {
            let afterHome = path[range.upperBound...]
            if let slash = afterHome.firstIndex(of: "/") {
                return "~" + afterHome[slash...]
            }
            return "~"
        }
        return path
    }
}

// Sheet for configuring extra search directories
struct SearchDirectoriesSheet: View {
    @Binding var searchDirectories: [String]
    let currentDirectory: String
    @Environment(\.dismiss) private var dismiss
    @State private var newPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: RD.Spacing.md) {
            HStack {
                Text("Search Directories")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.return)
            }

            Text("When the filter bar finds nothing in the current directory, these locations are also searched.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            // Current directory (always searched, not removable)
            HStack(spacing: RD.Spacing.sm) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text(currentDirectory)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("current")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ForEach(searchDirectories, id: \.self) { dir in
                HStack(spacing: RD.Spacing.sm) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(dir)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        searchDirectories.removeAll { $0 == dir }
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }

            Divider()

            HStack(spacing: RD.Spacing.sm) {
                Image(systemName: "plus.circle").foregroundStyle(.secondary)
                TextField("/path/to/directory", text: $newPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .onSubmit { addDirectory() }
                Button("Add", action: addDirectory)
                    .disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Spacer()
        }
        .padding(RD.Spacing.lg)
        .frame(width: 420, height: 340)
    }

    private func addDirectory() {
        let path = newPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !searchDirectories.contains(path), path != currentDirectory else { return }
        searchDirectories.append(path)
        newPath = ""
    }
}

// Simple flow layout for directory chips
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let rowHeight = row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
            height += rowHeight + (i > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
            var x = bounds.minX
            for index in row {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[Int]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[Int]] = [[]]
        var currentWidth: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentWidth = 0
            }
            rows[rows.count - 1].append(index)
            currentWidth += size.width + spacing
        }
        return rows
    }
}
