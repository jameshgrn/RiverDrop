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
                ContentUnavailableView("Everything is in sync", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fileList
            }

            Divider()
            footer
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Sync Preview")
                .font(.headline)
            Spacer()
            Text(summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if result.totalBytes > 0 {
                Text("(\(ByteCountFormatter.string(fromByteCount: result.totalBytes, countStyle: .file)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - File List

    private var fileList: some View {
        List {
            if !result.added.isEmpty {
                Section {
                    ForEach(result.added) { entry in
                        fileRow(entry, color: .green, icon: "plus.circle.fill")
                    }
                } header: {
                    Label("Added (\(result.added.count))", systemImage: "plus.circle")
                        .foregroundStyle(.green)
                }
            }

            if !result.modified.isEmpty {
                Section {
                    ForEach(result.modified) { entry in
                        fileRow(entry, color: .orange, icon: "pencil.circle.fill")
                    }
                } header: {
                    Label("Modified (\(result.modified.count))", systemImage: "pencil.circle")
                        .foregroundStyle(.orange)
                }
            }

            if !result.deleted.isEmpty {
                Section {
                    ForEach(result.deleted) { entry in
                        fileRow(entry, color: .red, icon: "minus.circle.fill")
                    }
                } header: {
                    Label("Deleted (\(result.deleted.count))", systemImage: "minus.circle")
                        .foregroundStyle(.red)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Sync") {
                onConfirm()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(result.isEmpty)
        }
        .padding()
    }

    // MARK: - Helpers

    private func fileRow(_ entry: DryRunFileEntry, color: Color, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(entry.path)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if entry.size > 0 {
                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summaryText: String {
        var parts: [String] = []
        if !result.added.isEmpty { parts.append("\(result.added.count) added") }
        if !result.modified.isEmpty { parts.append("\(result.modified.count) modified") }
        if !result.deleted.isEmpty { parts.append("\(result.deleted.count) deleted") }
        return parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
    }
}
