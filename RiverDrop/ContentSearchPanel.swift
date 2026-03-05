import SwiftUI

/// A reusable ripgrep content search panel.
///
/// Accepts an `ObservableObject` conforming to `RipgrepSearch` directly, plus
/// closures for executing search and navigating to a result. This keeps it
/// decoupled from any particular browser view.
struct ContentSearchPanel: View {
    @ObservedObject var ripgrepSearch: RipgrepSearch
    @Binding var contentSearchQuery: String
    @Binding var isRecursiveSearch: Bool
    @Binding var fileTypeFilter: String

    /// Called when the user presses Enter or taps Play.
    var onSearch: () -> Void
    /// Called when the user clicks a search result row.
    var onNavigateToResult: (RipgrepResult) -> Void

    private var parsedFileTypes: [String] {
        fileTypeFilter
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RD.Spacing.sm) {
            searchField
            optionsRow
            limitsRow
            statusSection
            resultsSection
        }
        .padding(.horizontal, RD.Spacing.md)
        .padding(.vertical, RD.Spacing.sm)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }

    // MARK: - Subviews

    private var searchField: some View {
        HStack(spacing: RD.Spacing.sm) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                TextField("Search file contents\u{2026}", text: $contentSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .onSubmit { onSearch() }
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
                .accessibilityLabel("Cancel search")
            } else {
                Button { onSearch() } label: {
                    Image(systemName: "play.fill")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Run search")
                .accessibilityLabel("Run search")
            }
        }
    }

    private var optionsRow: some View {
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
    }

    private var limitsRow: some View {
        HStack(spacing: RD.Spacing.md) {
            HStack(spacing: RD.Spacing.xs) {
                Text("Max results:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("100", value: $ripgrepSearch.maxCount, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .font(.caption)
                    .monospacedDigit()
            }

            HStack(spacing: RD.Spacing.xs) {
                Text("Max line length:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("200", value: $ripgrepSearch.maxColumns, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .font(.caption)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
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
    }

    @ViewBuilder
    private var resultsSection: some View {
        if !ripgrepSearch.results.isEmpty {
            StatusBadge(
                text: "\(ripgrepSearch.resultCount) match\(ripgrepSearch.resultCount == 1 ? "" : "es")",
                color: .riverPrimary
            )

            List(ripgrepSearch.results) { result in
                Button { onNavigateToResult(result) } label: {
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
}
