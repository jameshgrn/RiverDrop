import SwiftUI

struct DryRunPreviewView: View {
    let result: DryRunResult
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if result.isEmpty {
                EmptyStateView("Everything in sync", icon: "checkmark.circle", subtitle: "No changes needed")
            } else {
                fileList
            }

            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: RD.cornerRadiusLarge))
        .frame(minWidth: 520, minHeight: 420)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: RD.Spacing.sm) {
            PaneHeader("Sync Preview", icon: "arrow.triangle.2.circlepath")

            HStack(spacing: RD.Spacing.sm) {
                StatusBadge(text: "\(result.added.count) added", color: .green)
                StatusBadge(text: "\(result.modified.count) modified", color: .orange)
                StatusBadge(text: "\(result.deleted.count) deleted", color: .red)

                Spacer()

                if result.totalBytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: result.totalBytes, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, RD.Spacing.md)
            .padding(.bottom, RD.Spacing.sm)
        }
    }

    // MARK: - File List

    private var fileList: some View {
        ScrollView {
            VStack(spacing: RD.Spacing.lg) {
                if !result.added.isEmpty {
                    fileSection(
                        title: "Added",
                        icon: "plus.circle.fill",
                        color: .green,
                        entries: result.added
                    )
                }

                if !result.modified.isEmpty {
                    fileSection(
                        title: "Modified",
                        icon: "pencil.circle.fill",
                        color: .orange,
                        entries: result.modified
                    )
                }

                if !result.deleted.isEmpty {
                    fileSection(
                        title: "Deleted",
                        icon: "minus.circle.fill",
                        color: .red,
                        entries: result.deleted
                    )
                }
            }
            .padding(RD.Spacing.md)
        }
    }

    private func fileSection(title: String, icon: String, color: Color, entries: [DryRunFileEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: RD.Spacing.sm) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)
                Text("\(title) (\(entries.count))")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(color)
            }
            .padding(.horizontal, RD.Spacing.md)
            .padding(.vertical, RD.Spacing.sm)

            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    fileRow(entry)
                        .padding(.horizontal, RD.Spacing.md)
                        .padding(.vertical, RD.Spacing.sm)
                        .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.02))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: RD.cornerRadiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: RD.cornerRadiusSmall)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
        }
    }

    private func fileRow(_ entry: DryRunFileEntry) -> some View {
        HStack(spacing: RD.Spacing.sm) {
            FileIconView(
                filename: (entry.path as NSString).lastPathComponent,
                isDirectory: entry.path.hasSuffix("/"),
                size: 14
            )

            Text(entry.path)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            if entry.size > 0 {
                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button {
                onConfirm()
            } label: {
                Text("Sync \(result.totalFiles) files")
            }
            .buttonStyle(RDButtonStyle(isProminent: true))
            .keyboardShortcut(.defaultAction)
            .disabled(result.isEmpty)
        }
        .padding(.horizontal, RD.Spacing.lg)
        .padding(.vertical, RD.Spacing.md)
    }
}
