// Purpose: Fixes misspelled proper nouns in a finished transcript by fuzzy-matching against known
//          terms (participant names from the calendar event, project name, meeting title). Applies
//          to every engine, so it also covers Parakeet — whose decoder cannot be biased through the
//          batch API the app uses.
// Dependencies: none (pure string processing, unit-tested in isolation).
// Used by: Sources/App/ViewModels/AppViewModel.swift (after each transcription completes).
// Notes: Deliberately conservative — the goal is fixing near-misses ("Anna Schmitt" → "Anna Schmid"),
//        never rewriting text that is already correct:
//        - Only edit distances of 1…3 (scaled to term length) are corrected; an exact
//          case-insensitive match is left untouched, so common words that happen to equal a project
//          name are never re-capitalized.
//        - Terms shorter than 4 characters or longer than 3 words are ignored (too collision-prone).
//        - The "[MM:SS] Speaker:" line prefix is preserved verbatim so timestamps and speaker
//          labels can never be altered.

import Foundation

enum ProperNounCorrection {

    private static let minTermLength = 4
    private static let maxTermWords = 3

    /// A term prepared for matching, with its words pre-split and normalized.
    private struct Candidate {
        let original: String
        let words: [String]
        let normalized: String
        let tolerance: Int
    }

    /// Corrects near-miss spellings of `terms` in `text`.
    /// - Returns: the corrected transcript and how many replacements were made.
    static func correct(_ text: String, terms: [String]) -> (text: String, replacements: Int) {
        let candidates = prepare(terms)
        guard !candidates.isEmpty, !text.isEmpty else { return (text, 0) }

        var totalReplacements = 0
        let corrected = text.components(separatedBy: "\n").map { line -> String in
            let (prefix, body) = splitSpeakerPrefix(line)
            let (newBody, count) = correctBody(body, candidates: candidates)
            totalReplacements += count
            return prefix + newBody
        }

        return (corrected.joined(separator: "\n"), totalReplacements)
    }

    // MARK: - Preparation

    private static func prepare(_ terms: [String]) -> [Candidate] {
        var seen = Set<String>()
        var candidates: [Candidate] = []

        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= minTermLength else { continue }

            let words = trimmed.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            guard !words.isEmpty, words.count <= maxTermWords else { continue }
            // Must contain letters — skip numeric or symbol-only entries.
            guard trimmed.rangeOfCharacter(from: .letters) != nil else { continue }

            let normalized = trimmed.lowercased()
            guard seen.insert(normalized).inserted else { continue }

            candidates.append(
                Candidate(
                    original: trimmed,
                    words: words,
                    normalized: normalized,
                    tolerance: tolerance(forLength: trimmed.count)))
        }

        // Longer / multi-word terms first so "Anna Schmid" wins over "Anna".
        return candidates.sorted {
            $0.words.count != $1.words.count
                ? $0.words.count > $1.words.count
                : $0.original.count > $1.original.count
        }
    }

    /// Allowed edit distance, scaled to term length.
    private static func tolerance(forLength length: Int) -> Int {
        switch length {
        case ..<7: return 1
        case ..<12: return 2
        default: return 3
        }
    }

    /// Splits a rendered transcript line into its "[MM:SS] Speaker: " prefix and the spoken body.
    /// Lines without a prefix are returned unchanged as the body.
    private static func splitSpeakerPrefix(_ line: String) -> (prefix: String, body: String) {
        guard line.hasPrefix("["),
            let bracketEnd = line.firstIndex(of: "]"),
            let colon = line[bracketEnd...].firstIndex(of: ":")
        else { return ("", line) }

        // Expect ": " after the speaker label.
        let afterColon = line.index(after: colon)
        guard afterColon < line.endIndex, line[afterColon] == " " else { return ("", line) }

        let splitPoint = line.index(after: afterColon)
        return (String(line[..<splitPoint]), String(line[splitPoint...]))
    }

    // MARK: - Matching

    private static func correctBody(_ body: String, candidates: [Candidate]) -> (String, Int) {
        guard !body.isEmpty else { return (body, 0) }

        let wordRanges = self.wordRanges(in: body)
        guard !wordRanges.isEmpty else { return (body, 0) }

        // Collected replacements as (range in body, replacement text).
        var replacements: [(range: Range<String.Index>, text: String)] = []
        var consumed = [Bool](repeating: false, count: wordRanges.count)

        for candidate in candidates {
            let window = candidate.words.count
            guard window <= wordRanges.count else { continue }

            for start in 0...(wordRanges.count - window) {
                let indices = Array(start..<(start + window))
                if indices.contains(where: { consumed[$0] }) { continue }

                let range = wordRanges[start].lowerBound..<wordRanges[start + window - 1].upperBound
                let phrase = String(body[range])
                let normalizedPhrase = phrase.lowercased()

                // Already correct (ignoring case) — leave it alone.
                if normalizedPhrase == candidate.normalized { continue }

                let distance = editDistance(normalizedPhrase, candidate.normalized)
                guard distance > 0, distance <= candidate.tolerance else { continue }

                replacements.append((range: range, text: candidate.original))
                indices.forEach { consumed[$0] = true }
            }
        }

        guard !replacements.isEmpty else { return (body, 0) }

        // Apply back-to-front so earlier ranges stay valid.
        var result = body
        for replacement in replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(replacement.range, with: replacement.text)
        }
        return (result, replacements.count)
    }

    /// Ranges of word-like runs (letters, plus internal apostrophes/hyphens).
    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var current: String.Index?
        let joiners = CharacterSet(charactersIn: "'’-")

        for index in text.indices {
            let scalar = text[index].unicodeScalars.first!
            let isWordChar =
                CharacterSet.letters.contains(scalar) || joiners.contains(scalar)
            if isWordChar {
                if current == nil { current = index }
            } else if let start = current {
                ranges.append(start..<index)
                current = nil
            }
        }
        if let start = current { ranges.append(start..<text.endIndex) }
        return ranges
    }

    /// Levenshtein distance (iterative, two rows).
    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        if lhs == rhs { return 0 }
        let a = Array(lhs), b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,        // deletion
                    current[j - 1] + 1,     // insertion
                    previous[j - 1] + cost  // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
