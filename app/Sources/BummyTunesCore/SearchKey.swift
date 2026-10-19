import Foundation

/// Script-aware search folding (R12).
///
/// The naive approach, `folding(options: .diacriticInsensitive)`, strips every
/// combining mark. That is correct for Latin accents and catastrophic for
/// Japanese: the dakuten and handakuten (U+3099, U+309A) are combining marks
/// but they change the consonant, so か and が are different words. Measured on
/// a real library it turned ゴミ into コミ and あなたがすき into あなたかすき.
///
/// This folds only the Latin combining-diacritic block and leaves kana voicing
/// intact, so `Pois É` and `Pois E` meet at `pois e` while Japanese survives.
public enum SearchKey {

    /// Combining Diacritical Marks, U+0300...U+036F. Safe to strip.
    private static let latinMarks: ClosedRange<UInt32> = 0x0300...0x036F
    /// Japanese voiced/semi-voiced sound marks. Must be preserved.
    private static let kanaVoicing: Set<UInt32> = [0x3099, 0x309A]

    /// Fold a string into its search key. Fold once on write, never on read.
    public static func fold(_ s: String) -> String {
        // NFKD also normalises full-width/half-width forms (R12.3).
        let decomposed = s.decomposedStringWithCompatibilityMapping
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(decomposed.unicodeScalars.count)
        for u in decomposed.unicodeScalars {
            if kanaVoicing.contains(u.value) { scalars.append(u); continue }
            if latinMarks.contains(u.value) { continue }
            scalars.append(u)
        }
        return String(scalars)
            .precomposedStringWithCanonicalMapping
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Does `haystack`'s folded key contain the folded `needle`?
    public static func matches(_ needle: String, in haystack: String) -> Bool {
        let n = fold(needle)
        return n.isEmpty || fold(haystack).contains(n)
    }
}

// MARK: - Typo tolerance (R12.6)

public extension SearchKey {
    /// Split folded text into terms.
    ///
    /// Anything that is not a letter or a digit is a separator, so "Luv(sic)"
    /// becomes "luv" and "sic", and a search for either finds it.
    static func terms(_ folded: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Terms straight from raw text.
    static func terms(raw: String) -> [String] { terms(fold(raw)) }
}

public enum EditDistance {
    /// Bounded Levenshtein. Returns `limit + 1` once it is certain the distance
    /// exceeds `limit`, so the common "not close" case exits cheaply.
    public static func within(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        if abs(x.count - y.count) > limit { return limit + 1 }
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }

        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }
}
