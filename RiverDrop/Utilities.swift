import Foundation
import UniformTypeIdentifiers

enum RiverDropDragType {
    static let remoteFile = UTType(exportedAs: "com.riverdrop.remote-file")
}

struct RemoteDragPayload: Codable {
    let remotePath: String
    let filename: String
    let size: UInt64
}

// MARK: - Fuzzy Matching

struct FuzzyMatchResult: Sendable {
    let score: Int
    let matchedRanges: [Range<String.Index>]
}

/// Fuzzy match `pattern` against `text` using Alfred-inspired heuristics.
///
/// Returns nil if the pattern is not a subsequence of the text.
/// Score incorporates: exact prefix, word boundaries, camelCase, acronyms,
/// exponential consecutive bonus, gap penalties, position decay, length
/// preference, and case-sensitive refinement.
func fuzzyMatch(pattern: String, text: String) -> FuzzyMatchResult? {
    guard !pattern.isEmpty else {
        return FuzzyMatchResult(score: 1, matchedRanges: [])
    }
    guard !text.isEmpty else { return nil }

    let pUnits = Array(pattern.utf16)
    let pLower = pUnits.map { _asciiLow($0) }

    guard let (score, positions) = _fuzzyCore(pUnits: pUnits, pLower: pLower, text: text) else {
        return nil
    }

    // Convert UTF-16 positions to String.Index ranges
    let utf16 = text.utf16
    let allIdx = Array(utf16.indices) + [utf16.endIndex]
    let ranges = _mergeRanges(positions: positions, indices: allIdx)

    return FuzzyMatchResult(score: score, matchedRanges: ranges)
}

func fuzzyFilter<T>(items: [T], query: String, getText: (T) -> String) -> [T] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return items }

    let pUnits = Array(trimmed.utf16)
    let pLower = pUnits.map { _asciiLow($0) }

    var scored: [(item: T, score: Int)] = []
    for item in items {
        if let (sc, _) = _fuzzyCore(pUnits: pUnits, pLower: pLower, text: getText(item)) {
            scored.append((item, sc))
        }
    }

    if !scored.isEmpty {
        scored.sort { $0.score > $1.score }
        return scored.map(\.item)
    }

    // Fallback: substring containment
    let lower = trimmed.lowercased()
    return items.filter { getText($0).lowercased().contains(lower) }
}

func fuzzyFilterWithRanges<T>(
    items: [T], query: String, getText: (T) -> String
) -> [(item: T, matchedRanges: [Range<String.Index>])] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
        return items.map { (item: $0, matchedRanges: []) }
    }

    var scored: [(item: T, score: Int, ranges: [Range<String.Index>])] = []
    for item in items {
        if let r = fuzzyMatch(pattern: trimmed, text: getText(item)) {
            scored.append((item, r.score, r.matchedRanges))
        }
    }

    if !scored.isEmpty {
        scored.sort { $0.score > $1.score }
        return scored.map { (item: $0.item, matchedRanges: $0.ranges) }
    }

    let lower = trimmed.lowercased()
    return items.compactMap { item in
        getText(item).lowercased().contains(lower) ? (item: item, matchedRanges: []) : nil
    }
}

func droppedFileURL(from item: NSSecureCoding?) -> URL? {
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

// MARK: - Core Algorithm

/// Core fuzzy scoring using DP on UTF-16 code units.
/// Returns (score, matchedUTF16Positions) or nil.
private func _fuzzyCore(
    pUnits: [UInt16], pLower: [UInt16], text: String
) -> (Int, [Int])? {
    let tUnits = Array(text.utf16)
    let tLen = tUnits.count
    let pLen = pUnits.count

    guard pLen <= tLen else { return nil }

    // Inline ASCII lowercasing — avoids String.lowercased() allocation
    let tLower = tUnits.map { _asciiLow($0) }

    // Quick subsequence reject — O(n)
    var pi = 0
    for ti in 0..<tLen where pi < pLen {
        if tLower[ti] == pLower[pi] { pi += 1 }
    }
    guard pi == pLen else { return nil }

    // Exact match fast path
    if pLen == tLen && pLower == tLower {
        var cb = 0
        for i in 0..<pLen where pUnits[i] == tUnits[i] { cb += kExactCase }
        let s = pLen * kMatch + pLen * kPrefix + cb + kMaxLenBonus + kFirstChar
        return (s, Array(0..<pLen))
    }

    // Character classification (0=plain, 1=boundary, 2=dot, 3=camel)
    var cls = [UInt8](repeating: 0, count: tLen)
    cls[0] = 1
    for i in 1..<tLen {
        let p = tUnits[i - 1]
        let c = tUnits[i]
        if p == 0x2F || p == 0x20 || p == 0x5F || p == 0x2D { //  / _-
            cls[i] = 1
        } else if p == 0x2E { // .
            cls[i] = 2
        } else if _isLow(p) && _isUp(c) {
            cls[i] = 3
        } else if i + 1 < tLen && _isUp(p) && _isUp(c) && _isLow(tUnits[i + 1]) {
            cls[i] = 3
        }
    }

    // Flat DP arrays: H=score, D=consecutive streak, S=backtrack source
    let negInf = Int.min / 2
    let n = pLen * tLen
    var H = [Int](repeating: negInf, count: n)
    var D = [Int](repeating: 0, count: n)
    var S = [Int](repeating: -1, count: n)

    // Row 0
    for j in 0..<tLen where tLower[j] == pLower[0] {
        var sc = kMatch + _clsVal(cls[j])
        if j == 0 { sc += kFirstChar }
        if tUnits[j] == pUnits[0] { sc += kExactCase }
        H[j] = sc
        D[j] = 1
    }

    // Rows 1..<pLen
    for i in 1..<pLen {
        let row = i * tLen
        let prevRow = (i - 1) * tLen
        var bestPrev = negInf
        var bestPrevJ = -1

        for j in i..<tLen {
            let ph = H[prevRow + j - 1]
            if ph > bestPrev { bestPrev = ph; bestPrevJ = j - 1 }

            guard tLower[j] == pLower[i] else { continue }

            var mb = kMatch + _clsVal(cls[j])
            if tUnits[j] == pUnits[i] { mb += kExactCase }
            let k = row + j

            // Consecutive
            var csc = negInf
            var streak = 1
            let ph2 = H[prevRow + j - 1]
            if ph2 > negInf {
                let ps = D[prevRow + j - 1]
                csc = ph2 + mb + min(1 << ps, kMaxConsec)
                streak = ps + 1
            }

            // Gap
            var gsc = negInf
            if bestPrev > negInf {
                gsc = bestPrev + mb + kGapStart
            }

            if csc >= gsc && csc > negInf {
                H[k] = csc; D[k] = streak; S[k] = j - 1
            } else if gsc > negInf {
                H[k] = gsc; D[k] = 1; S[k] = bestPrevJ
            }
        }
    }

    // Best endpoint
    let lastRow = (pLen - 1) * tLen
    var bestScore = negInf
    var bestJ = -1
    for j in (pLen - 1)..<tLen {
        let s = H[lastRow + j]
        if s > bestScore { bestScore = s; bestJ = j }
    }
    guard bestScore > negInf else { return nil }

    // Backtrack
    var pos = [Int](repeating: 0, count: pLen)
    pos[pLen - 1] = bestJ
    for i in stride(from: pLen - 2, through: 0, by: -1) {
        pos[i] = S[(i + 1) * tLen + pos[i + 1]]
    }

    // Post-hoc bonuses
    var fs = bestScore

    // Prefix bonus
    if pos[0] == 0 {
        var pl = 1
        for i in 1..<pLen {
            if pos[i] == i { pl += 1 } else { break }
        }
        fs += pl * kPrefix
    }

    // Acronym bonus — only boundary(1) and camel(3), NOT dot(2)
    if pLen > 1 {
        let allInitials = pos.allSatisfy { cls[$0] == 1 || cls[$0] == 3 }
        if allInitials { fs += pLen * kAcronym }
    }

    // Shorter name preference
    fs += max(0, kMaxLenBonus - tLen / 3)

    // Position decay
    let pd = pos.reduce(0) { $0 + (tLen - $1) }
    fs += pd / max(pLen, 1) / 4

    // Gap extension penalty — penalizes spread between first and last match
    if pLen > 1 {
        let totalGap = pos[pLen - 1] - (pLen - 1)
        fs += kGapExt * totalGap
    }

    return (fs, pos)
}

// MARK: - Helpers

private func _mergeRanges(
    positions: [Int], indices: [String.Index]
) -> [Range<String.Index>] {
    guard !positions.isEmpty else { return [] }
    var ranges: [Range<String.Index>] = []
    var rStart = positions[0]
    var rEnd = positions[0]
    for i in 1..<positions.count {
        if positions[i] == rEnd + 1 {
            rEnd = positions[i]
        } else {
            ranges.append(indices[rStart]..<indices[rEnd + 1])
            rStart = positions[i]
            rEnd = positions[i]
        }
    }
    ranges.append(indices[rStart]..<indices[rEnd + 1])
    return ranges
}

@inline(__always) private func _asciiLow(_ c: UInt16) -> UInt16 {
    (c >= 0x41 && c <= 0x5A) ? c | 0x20 : c
}
@inline(__always) private func _isUp(_ c: UInt16) -> Bool { c >= 0x41 && c <= 0x5A }
@inline(__always) private func _isLow(_ c: UInt16) -> Bool { c >= 0x61 && c <= 0x7A }

@inline(__always) private func _clsVal(_ c: UInt8) -> Int {
    switch c {
    case 1: return kBoundary
    case 2: return kDot
    case 3: return kCamel
    default: return 0
    }
}

// MARK: - Scoring Constants

private let kMatch = 16
private let kGapStart = -3
private let kGapExt = -1
private let kBoundary = 8
private let kCamel = 7
private let kDot = 6
private let kFirstChar = 10
private let kMaxConsec = 16
private let kExactCase = 2
private let kPrefix = 12
private let kAcronym = 14
private let kMaxLenBonus = 20

// MARK: - Test Vectors
// "dsi" → "DirectorySearchIndex.swift" should match (acronym)
// "data" → "dataset.csv" should score higher than "my_data_file.csv"
// "rb" → "RemoteBrowserView.swift" should score higher than "arbitrary.swift"
// "sftp" → "SFTPService.swift" should match (exact substring + word boundary)
// "util" → "Utilities.swift" should score higher than "execution_utilities_v2.py"
// exact match "README.md" → "README.md" should be top result
