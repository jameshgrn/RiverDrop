import Foundation
import os

private let searchLogger = Logger(subsystem: "com.riverdrop", category: "DirectorySearchIndex")

/// Pre-built filename index for fast fuzzy search over large directories.
///
/// Designed to work with both `RemoteFileItem` and `LocalFileItem` (or any type that
/// has a filename). Build the index once after loading a directory, then query it
/// repeatedly as the user types.
///
/// Features:
/// - Pre-cached original filenames avoid repeated closure calls per keystroke.
/// - Cancellable: new queries cancel in-flight searches automatically.
/// - Progressive results: scannedCount updates periodically during search.
/// - Runs search work on a detached task to keep the main actor responsive.
/// - Returns `SearchResult` with matched ranges for UI highlighting.
///
/// Usage:
///   let index = DirectorySearchIndex<RemoteFileItem>()
///   index.build(from: items) { $0.filename }
///   await index.search(query: "data") // returns matching items sorted by fuzzy score
@MainActor
@Observable
final class DirectorySearchIndex<Item: Identifiable & Sendable> {

    // MARK: - Search Result

    struct SearchResult: Sendable {
        let item: Item
        let matchedRanges: [Range<String.Index>]
    }

    // MARK: - Published state

    /// The current search results, updated progressively.
    private(set) var results: [SearchResult] = []

    /// Whether a search is currently running.
    private(set) var isSearching = false

    /// How many items have been scanned so far in the current search.
    private(set) var scannedCount: Int = 0

    /// Total number of indexed items.
    private(set) var indexedCount: Int = 0

    // MARK: - Internal

    /// Each entry pairs an item with its original filename.
    private var entries: [Entry] = []

    /// Currently running search task -- cancelled when a new search starts.
    private var searchTask: Task<Void, Never>?

    /// The detached fuzzy-match task -- must be cancelled separately from searchTask.
    private var detachedSearchTask: Task<[ScoredResult], Never>?

    private struct Entry: Sendable {
        let item: Item
        let name: String
    }

    // MARK: - Build

    /// Build (or rebuild) the search index from a list of items.
    ///
    /// - Parameters:
    ///   - items: The full directory listing.
    ///   - nameKeyPath: Closure that extracts the filename from an item.
    func build(from items: [Item], name nameKeyPath: @escaping @Sendable (Item) -> String) {
        cancel()
        entries = items.map { Entry(item: $0, name: nameKeyPath($0)) }
        indexedCount = items.count
        results = []
        scannedCount = 0
        searchLogger.debug("Built search index with \(items.count) entries")
    }

    /// Clear the index entirely (e.g. on disconnect).
    func clear() {
        cancel()
        entries = []
        indexedCount = 0
        results = []
        scannedCount = 0
    }

    // MARK: - Search

    /// Run a fuzzy search. Cancels any in-flight search.
    ///
    /// Results are written progressively to `self.results` in batches of `batchSize`.
    /// Returns the final result array for callers that want to await it.
    ///
    /// - Parameters:
    ///   - query: The user's search text. Empty string clears results.
    ///   - batchSize: How many items to process before yielding back to the main actor.
    ///                Smaller = more responsive UI, larger = faster total search.
    /// - Returns: The final sorted array of matching items with match ranges.
    @discardableResult
    func search(query: String, batchSize: Int = 5_000) async -> [SearchResult] {
        // Cancel previous search.
        searchTask?.cancel()
        searchTask = nil
        detachedSearchTask?.cancel()
        detachedSearchTask = nil

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            scannedCount = 0
            isSearching = false
            return []
        }

        isSearching = true
        scannedCount = 0
        results = []

        let snapshot = entries
        let pattern = trimmed

        // Run the scan on a detached task to avoid blocking the main actor.
        let task = Task<[ScoredResult], Never>.detached(priority: .userInitiated) { [pattern] in

            var scored: [ScoredResult] = []
            scored.reserveCapacity(snapshot.count / 4)

            for (index, entry) in snapshot.enumerated() {
                if Task.isCancelled { return [] }

                if let match = fuzzyMatch(pattern: pattern, text: entry.name) {
                    scored.append(ScoredResult(
                        item: entry.item,
                        score: match.score,
                        matchedRanges: match.matchedRanges
                    ))
                }

                // Yield progress periodically.
                if (index + 1).isMultiple(of: batchSize) {
                    let currentIndex = index + 1
                    await Self.updateScannedCount(on: self, count: currentIndex)
                }
            }

            if Task.isCancelled { return [] }

            // Sort by score descending.
            scored.sort { $0.score > $1.score }
            return scored
        }
        detachedSearchTask = task

        searchTask = Task {
            let scored = await task.value
            guard !Task.isCancelled else { return }
            results = scored.map { SearchResult(item: $0.item, matchedRanges: $0.matchedRanges) }
            scannedCount = snapshot.count
            isSearching = false
        }

        // Await completion so callers can use the return value.
        await searchTask?.value
        return results
    }

    /// Cancel any in-flight search.
    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        detachedSearchTask?.cancel()
        detachedSearchTask = nil
        isSearching = false
    }

    // MARK: - Internal Types

    private struct ScoredResult: Sendable {
        let item: Item
        let score: Int
        let matchedRanges: [Range<String.Index>]
    }

    /// Helper to update scanned count from a detached task.
    private static func updateScannedCount(
        on index: DirectorySearchIndex<Item>,
        count: Int
    ) async {
        await MainActor.run {
            guard !Task.isCancelled else { return }
            index.scannedCount = count
        }
    }
}
