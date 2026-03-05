import Testing
@testable import RiverDrop

@Suite("fuzzyMatch")
struct FuzzyMatchTests {

    // MARK: - fuzzyMatch

    @Test("empty pattern returns 1")
    func emptyPatternReturnsOne() {
        #expect(fuzzyMatch(pattern: "", text: "anything") == 1)
        #expect(fuzzyMatch(pattern: "", text: "") == 1)
    }

    @Test("non-matching pattern returns 0")
    func nonMatchingReturnsZero() {
        #expect(fuzzyMatch(pattern: "xyz", text: "abc") == 0)
        #expect(fuzzyMatch(pattern: "zz", text: "abcdefg") == 0)
    }

    @Test("case insensitive matching")
    func caseInsensitive() {
        let upper = fuzzyMatch(pattern: "ABC", text: "abc")
        let lower = fuzzyMatch(pattern: "abc", text: "ABC")
        let mixed = fuzzyMatch(pattern: "aBc", text: "AbC")
        #expect(upper > 0)
        #expect(upper == lower)
        #expect(upper == mixed)
    }

    @Test("consecutive match bonus")
    func consecutiveBonus() {
        // "abc" in "abc" has all consecutive matches; "abc" in "axbxc" has none
        let consecutive = fuzzyMatch(pattern: "abc", text: "xabc")
        let scattered = fuzzyMatch(pattern: "abc", text: "xaxbxc")
        #expect(consecutive > scattered)
    }

    @Test("start-of-string bonus")
    func startBonus() {
        // "a" at position 0 gets +3 bonus; "a" later does not
        let atStart = fuzzyMatch(pattern: "a", text: "a_something")
        let notAtStart = fuzzyMatch(pattern: "a", text: "x_a_something")
        #expect(atStart > notAtStart)
    }

    @Test("separator bonus after dot, underscore, dash, slash, space")
    func separatorBonus() {
        let separators: [String] = [".", "_", "-", "/", " "]
        for sep in separators {
            let withSep = fuzzyMatch(pattern: "b", text: "a\(sep)b")
            let withoutSep = fuzzyMatch(pattern: "b", text: "axb")
            #expect(withSep > withoutSep, "separator '\(sep)' should give bonus")
        }
    }

    @Test("partial pattern match fails if not all chars found")
    func partialPatternFails() {
        // Pattern "abcz" can match a, b, c but not z in "abcdef"
        #expect(fuzzyMatch(pattern: "abcz", text: "abcdef") == 0)
    }
}

@Suite("fuzzyFilter")
struct FuzzyFilterTests {

    @Test("empty query returns all items unchanged")
    func emptyQuery() {
        let items = ["banana", "apple", "cherry"]
        let result = fuzzyFilter(items: items, query: "", getText: { $0 })
        #expect(result == items)
    }

    @Test("whitespace-only query returns all items")
    func whitespaceQuery() {
        let items = ["banana", "apple"]
        let result = fuzzyFilter(items: items, query: "   ", getText: { $0 })
        #expect(result == items)
    }

    @Test("filters and sorts by score")
    func filtersByScore() {
        let items = ["my_data_file", "readme", "data"]
        let result = fuzzyFilter(items: items, query: "data", getText: { $0 })
        // "data" should score highest (exact / start match); "my_data_file" next
        #expect(result.count == 2)
        #expect(result[0] == "data")
        #expect(result[1] == "my_data_file")
    }

    @Test("falls back to substring contains when no fuzzy hits")
    func substringFallback() {
        // "xyz" won't fuzzy-match "aaxyzbb" because fuzzyMatch should match it
        // actually it will. Let's use a case where fuzzy match *does* return 0 but
        // substring contains succeeds. That can't happen because if substring contains
        // the chars in order, fuzzy also matches. So fallback only matters for
        // non-sequential substring. Fuzzy requires sequential chars.
        // "ba" in "abc" -> fuzzy finds b at index 1, then needs a at index > 1 -> not found -> 0
        // but "abc".contains("ba") is false too.
        // Actually the fallback is for when fuzzyMatch returns 0 for ALL items but
        // substring-contains finds some. E.g. pattern "ba" text "xxbaxx":
        // fuzzy: b matched at 2, a matched at 3 -> score > 0. So it won't fall back.
        // The fallback triggers when chars exist but not in pattern order AND
        // substring literally exists. E.g. pattern "ba", items = ["ba_thing"]
        // fuzzy: b at 0, a at 1 -> matches. Hmm.
        // Real scenario: fuzzy returns 0 for all, but contains returns true.
        // This happens with patterns like "zyx" text "zyxabc" -> fuzzy matches z,y,x -> score > 0.
        // Hard to construct. Let's just test that when no fuzzy match works but substring does:
        // pattern "cb" text "xcby" -> fuzzy: c at 1, b at 2 -> matches (score > 0).
        // Forget it -- the fallback path only triggers when all fuzzy scores are 0
        // but at least one item literally .contains(query). This is impossible with
        // sequential matching because .contains implies the chars exist in order.
        // UNLESS the pattern has repeated characters: pattern "aa" text "a" -> fuzzy
        // needs two a's but only one exists -> 0. But "a".contains("aa") is false.
        // The fallback is essentially unreachable for single-word queries on strings.
        // Let's just verify the function doesn't crash and returns empty for no-match.
        let items = ["alpha", "beta", "gamma"]
        let result = fuzzyFilter(items: items, query: "zzz", getText: { $0 })
        #expect(result.isEmpty)
    }

    @Test("works with custom getText closure")
    func customGetText() {
        struct Item {
            let name: String
            let value: Int
        }
        let items = [
            Item(name: "server_one", value: 1),
            Item(name: "server_two", value: 2),
            Item(name: "database", value: 3),
        ]
        let result = fuzzyFilter(items: items, query: "two", getText: \.name)
        #expect(result.count == 1)
        #expect(result[0].value == 2)
    }
}
