import SwiftUI

/// A reusable SwiftUI wrapper that progressively renders items from a `DirectoryLoader`.
///
/// Mirrors the existing pattern in MainView/LocalBrowserView (start at 200, +200 on
/// scroll-to-bottom) but extracts it into a standalone, generic component.
///
/// Usage:
///   VirtualizedListView(loader: loader, selection: $selectedIDs) { item in
///       Text(item.filename)
///   }
struct VirtualizedListView<Item: Identifiable & Sendable, RowContent: View>: View {

    /// The loader whose `sortedItems` (or `items` while sorting) we render.
    let loader: DirectoryLoader<Item>

    /// Two-way binding for table-style multi-selection.
    @Binding var selection: Set<Item.ID>

    /// How many items to show per page. Defaults to 200 to match the existing convention.
    var pageSize: Int = 200

    /// The threshold (in items from the end) at which the next page is loaded.
    /// Using 1 matches the current "onAppear of sentinel row" pattern.
    var prefetchThreshold: Int = 1

    /// Builder for each row.
    @ViewBuilder var rowContent: (Item) -> RowContent

    // MARK: - Private state

    @State private var displayLimit: Int = 200

    // MARK: - Derived

    /// Use sorted items once available, fall back to unsorted during sort.
    private var sourceItems: [Item] {
        loader.sortedItems.isEmpty && !loader.items.isEmpty
            ? loader.items
            : loader.sortedItems
    }

    private var displayedItems: [Item] {
        Array(sourceItems.prefix(displayLimit))
    }

    private var hasMore: Bool {
        displayLimit < sourceItems.count
    }

    // MARK: - Body

    var body: some View {
        Group {
            if loader.isLoading {
                loadingIndicator
            } else if sourceItems.isEmpty && loader.error == nil {
                EmptyStateView("No items", icon: "folder", subtitle: "This directory is empty")
            } else {
                listContent
            }
        }
        .onChange(of: loader.totalCount) { _, _ in
            // Reset display limit when the underlying data changes (new directory loaded).
            displayLimit = pageSize
        }
    }

    // MARK: - Subviews

    private var listContent: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            List(selection: $selection) {
                ForEach(displayedItems) { item in
                    rowContent(item)
                        .tag(item.id)
                }
                if hasMore {
                    loadMoreSentinel
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    /// Top status bar showing counts and sort/loading state.
    private var statusBar: some View {
        HStack(spacing: RD.Spacing.sm) {
            // Sort indicator
            if loader.isSorting {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Sorting\u{2026}")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Count badge
            if loader.totalCount > 50_000 {
                StatusBadge(
                    text: "\(formatCount(loader.totalCount)) items -- large directory",
                    color: .orange
                )
            } else if hasMore {
                StatusBadge(
                    text: "\(formatCount(displayedItems.count))/\(formatCount(sourceItems.count))",
                    color: .secondary
                )
            } else if !sourceItems.isEmpty {
                StatusBadge(
                    text: "\(formatCount(sourceItems.count)) items",
                    color: .secondary
                )
            }
        }
        .padding(.horizontal, RD.Spacing.md)
        .padding(.vertical, RD.Spacing.xs)
        .frame(minHeight: 24)
    }

    /// Loading state shown during initial fetch.
    private var loadingIndicator: some View {
        VStack(spacing: RD.Spacing.md) {
            ProgressView()
            if loader.totalCount > 0 {
                Text("Loading \(formatCount(loader.loadedCount)) of \(formatCount(loader.totalCount)) files\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Loading\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Invisible sentinel row at the bottom of the list.
    /// When it scrolls into view, bump the display limit.
    private var loadMoreSentinel: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("Showing \(formatCount(displayedItems.count)) of \(formatCount(sourceItems.count))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, RD.Spacing.sm)
        .onAppear {
            displayLimit += pageSize
        }
    }

    // MARK: - Helpers

    /// Format large numbers with a thousands separator for readability.
    private func formatCount(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: - Convenience initializer without selection

extension VirtualizedListView where Item.ID: Hashable {
    /// Initializer for read-only lists that don't need selection.
    init(
        loader: DirectoryLoader<Item>,
        pageSize: Int = 200,
        @ViewBuilder rowContent: @escaping (Item) -> RowContent
    ) {
        self.loader = loader
        self._selection = .constant([])
        self.pageSize = pageSize
        self.rowContent = rowContent
    }
}
