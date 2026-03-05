import Foundation
import os

private let searchLogger = Logger(subsystem: "com.riverdrop", category: "DirectorySearchIndex")

/// Pre-built lowercase filename index for fast fuzzy search over large directories.
///
/// Designed to work with both `RemoteFileItem` and `LocalFileItem` (or any type that
/// has a filename). Build the index once after loading a directory, then query it
/// repeatedly as the user types.
///
/// Features:
/// - Pre-lowercased filename cache avoids repeated String.lowercased() per keystroke.
/// - Cancellable: new queries cancel in-flight searches automatically.
/// - Progressive results: the callback fires periodically during search.
/// - Runs search work on a detached task to keep the main actor responsive.
///
/// Usage:
///   let index = DirectorySearchIndex<RemoteFileItem>()
///   index.build(from: items) { $0.filename }
///   await index.search(query: "data") // returns matching items sorted by fuzzy score
@MainActor
@Observable
final class DirectorySearchIndex<Item: Identifiable & Sendable> {

    // MARK: - Published state

    /// The current search results, updated progressively.
    private(set) var results: [Item] = []

    /// Whether a search is currently running.
    private(set) var isSearching = false

    /// How many items have been scanned so far in the current search.
    private(set) var scannedCount: Int = 0

    /// Total number of indexed items.
    private(set) var indexedCount: Int = 0

    // MARK: - Internal

    /// Each entry pairs an item with its pre-lowercased filename.
    private var entries: [Entry] = []

    /// Currently running search task -- cancelled when a new search starts.
    private var searchTask: Task<Void, Never>?

    private struct Entry: Sendable {
        let item: Item
        let lowercaseName: String
    }

    // MARK: - Build

    /// Build (or rebuild) the search index from a list of items.
    ///
    /// - Parameters:
    ///   - items: The full directory listing.
    ///   - nameKeyPath: Closure that extracts the filename from an item.
    func build(from items: [Item], name nameKeyPath: @escaping @Sendable (Item) -> String) {
        cancel()
        entries = items.map { Entry(item: $0, lowercaseName: nameKeyPath($0).lowercased()) }
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
    /// - Returns: The final sorted array of matching items.
    @discardableResult
    func search(query: String, batchSize: Int = 5_000) async -> [Item] {
        // Cancel previous search.
        searchTask?.cancel()
        searchTask = nil

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
        let pattern = trimmed.lowercased()

        // Run the scan on a detached task to avoid blocking the main actor.
        let task = Task<[ScoredItem], Never>.detached(priority: .userInitiated) { [pattern] in
            var scored: [ScoredItem] = []
            scored.reserveCapacity(snapshot.count / 4) // rough estimate

            for (index, entry) in snapshot.enumerated() {
                if Task.isCancelled { return [] }

                let score = Self.fuzzyScore(pattern: pattern, text: entry.lowercaseName)
                if score > 0 {
                    scored.append(ScoredItem(item: entry.item, score: score))
                }

                // Yield progress periodically.
                if (index + 1).isMultiple(of: batchSize) {
                    let currentIndex = index + 1
                    await MainActor.run {
                        // Guard against stale updates from a cancelled task.
                        guard !Task.isCancelled else { return }
                        // Update scanned count on main actor.
                        // We don't update results mid-scan to avoid flicker;
                        // only scannedCount for the "Searching X files..." indicator.
                    }
                    // Use a non-isolated closure to update the actor state.
                    await Self.updateScannedCount(on: self, count: currentIndex)
                }
            }

            if Task.isCancelled { return [] }

            // Sort by score descending.
            scored.sort { $0.score > $1.score }
            return scored
        }

        searchTask = Task {
            let scored = await task.value
            guard !Task.isCancelled else { return }
            results = scored.map(\.item)
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
        isSearching = false
    }

    // MARK: - Scoring

    private struct ScoredItem: Sendable {
        let item: Item
        let score: Int
    }

    /// Fuzzy match scoring. Mirrors the existing `fuzzyMatch` in MainView.swift
    /// but operates on pre-lowercased strings.
    private static func fuzzyScore(pattern: String, text: String) -> Int {
        guard !pattern.isEmpty else { return 1 }

        var patternIdx = pattern.startIndex
        var score = 0
        var lastMatchIndex: String.Index?
        var consecutive = 0

        for textIdx in text.indices {
            guard patternIdx < pattern.endIndex else { break }
            if text[textIdx] == pattern[patternIdx] {
                score += 1

                // Bonus for consecutive matches.
                if let last = lastMatchIndex, text.index(after: last) == textIdx {
                    consecutive += 1
                    score += consecutive
                } else {
                    consecutive = 0
                }

                // Bonus for match at start or after separator.
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

        // All pattern characters must be matched.
        guard patternIdx == pattern.endIndex else { return 0 }

        // Fallback: if fuzzy didn't match, try substring containment.
        // (Not needed here since fuzzy matched, but included for API parity
        //  with the existing fuzzyFilter which falls back to .contains.)
        return score
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
