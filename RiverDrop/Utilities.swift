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

func fuzzyMatch(pattern: String, text: String) -> Int {
    guard !pattern.isEmpty else { return 1 }
    let pattern = pattern.lowercased()
    let text = text.lowercased()

    var patternIdx = pattern.startIndex
    var score = 0
    var lastMatchIndex: String.Index?
    var consecutive = 0

    for textIdx in text.indices {
        guard patternIdx < pattern.endIndex else { break }
        if text[textIdx] == pattern[patternIdx] {
            score += 1

            // Bonus for consecutive matches
            if let last = lastMatchIndex, text.index(after: last) == textIdx {
                consecutive += 1
                score += consecutive
            } else {
                consecutive = 0
            }

            // Bonus for match at start or after separator
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

    // All pattern characters must be matched
    return patternIdx == pattern.endIndex ? score : 0
}

func fuzzyFilter<T>(items: [T], query: String, getText: (T) -> String) -> [T] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return items }

    let scored = items.map { (item: $0, score: fuzzyMatch(pattern: trimmed, text: getText($0))) }
    let fuzzyHits = scored.filter { $0.score > 0 }
        .sorted { $0.score > $1.score }
        .map(\.item)
    if !fuzzyHits.isEmpty { return fuzzyHits }

    let lower = trimmed.lowercased()
    return items.filter { getText($0).lowercased().contains(lower) }
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
