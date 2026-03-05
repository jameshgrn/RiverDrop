import Foundation
import os

private let loaderLogger = Logger(subsystem: "com.riverdrop", category: "DirectoryLoader")

/// Generic async directory loader with progress tracking.
///
/// Loads items from any source (local filesystem, SFTP, etc.) then sorts them
/// in a background thread to keep the main actor responsive. Designed to replace
/// the inline load-then-sort pattern in both LocalBrowserView and MainView.
///
/// Usage:
///   let loader = DirectoryLoader<RemoteFileItem>()
///   try await loader.load(
///       fetch: { try await sftp.listDirectory(atPath: path) },
///       sort: { items in items.sorted { ... } }
///   )
///   // loader.items contains unsorted items immediately
///   // loader.sortedItems updates once background sort finishes
@MainActor
@Observable
final class DirectoryLoader<Item: Identifiable & Sendable> {

    // MARK: - Published state

    /// Raw items as returned by the fetch closure (unsorted).
    private(set) var items: [Item] = []

    /// Sorted items, ready for display. Empty until sort completes.
    private(set) var sortedItems: [Item] = []

    /// Whether a fetch is currently in progress.
    private(set) var isLoading = false

    /// Whether a background sort is currently in progress.
    private(set) var isSorting = false

    /// Total count of items returned by the last fetch.
    private(set) var totalCount: Int = 0

    /// Number of items loaded so far (equals totalCount once fetch completes).
    private(set) var loadedCount: Int = 0

    /// Non-nil if the last load or sort failed.
    private(set) var error: (any Error)?

    // MARK: - Internal

    private var loadTask: Task<Void, Never>?

    // MARK: - Load

    /// Fetch items from `fetch`, then sort them off the main actor via `sort`.
    ///
    /// Calling this while a previous load is in flight cancels the earlier one.
    ///
    /// - Parameters:
    ///   - fetch: An async closure that returns the full array of items.
    ///            Runs on whatever executor the caller provides (typically an actor).
    ///   - sort:  A pure, synchronous closure that returns a sorted copy.
    ///            Runs on a detached task to avoid blocking the main actor.
    func load(
        fetch: @Sendable () async throws -> [Item],
        sort: @escaping @Sendable ([Item]) -> [Item]
    ) async throws {
        // Cancel any in-flight load.
        loadTask?.cancel()
        loadTask = nil

        // Reset state.
        isLoading = true
        isSorting = false
        error = nil
        items = []
        sortedItems = []
        totalCount = 0
        loadedCount = 0

        do {
            let fetched = try await fetch()
            try Task.checkCancellation()

            items = fetched
            totalCount = fetched.count
            loadedCount = fetched.count
            isLoading = false

            if fetched.count > 50_000 {
                loaderLogger.warning("Directory contains \(fetched.count) items -- UI may be sluggish")
            }

            // Sort off-main-actor.
            isSorting = true
            let sorted = try await Self.backgroundSort(fetched, using: sort)
            try Task.checkCancellation()

            sortedItems = sorted
            isSorting = false
        } catch is CancellationError {
            // Silently swallow cancellation -- a newer load replaced this one.
            isLoading = false
            isSorting = false
        } catch {
            self.error = error
            isLoading = false
            isSorting = false
            throw error
        }
    }

    /// Convenience: re-sort the existing items without refetching.
    func resort(using sort: @escaping @Sendable ([Item]) -> [Item]) async {
        guard !items.isEmpty else { return }
        isSorting = true
        do {
            let sorted = try await Self.backgroundSort(items, using: sort)
            sortedItems = sorted
        } catch {
            // Cancelled or unexpected -- leave sortedItems as-is.
        }
        isSorting = false
    }

    /// Clear all state (e.g. on disconnect or directory change).
    func reset() {
        loadTask?.cancel()
        loadTask = nil
        items = []
        sortedItems = []
        isLoading = false
        isSorting = false
        totalCount = 0
        loadedCount = 0
        error = nil
    }

    // MARK: - Background sort

    private static func backgroundSort(
        _ items: [Item],
        using sort: @escaping @Sendable ([Item]) -> [Item]
    ) async throws -> [Item] {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return sort(items)
        }.value
    }
}
