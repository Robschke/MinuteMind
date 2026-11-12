// Purpose: VocabularyStore, the user's dictionary of words MinuteMind must get right: names,
//          abbreviations and jargon, each with the misheard forms that should become it
//          ("aus SEO" -> "Auth0"). Like Wispr Flow's dictionary.
// Dependencies: Foundation (JSON file vocabulary.json in the app's base directory)
// Used by: Sources/App/ViewModels/AppViewModel.swift (transcription biasing, corrections, cleanup
//          context), Sources/App/Views/DictionarySettingsView.swift (editing),
//          Sources/App/Services/MCP/MCPMeetingTools.swift (list/add for Claude)
// Notes: Entries are global (all projects); a project scope can be added later without migration
//        because the field is optional. Terms are unique case-insensitively; adding a term that
//        exists merges the variants. Saved atomically on every change.

import Foundation
import Observation

struct VocabularyEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    /// The correct spelling, e.g. "Auth0".
    var term: String
    /// Forms the recognizer produces instead, e.g. ["aus SEO", "auth zero"].
    var variants: [String]
    var createdAt: Date

    init(id: UUID = UUID(), term: String, variants: [String] = [], createdAt: Date = Date()) {
        self.id = id
        self.term = term
        self.variants = variants
        self.createdAt = createdAt
    }
}

@Observable
@MainActor
final class VocabularyStore {
    private(set) var entries: [VocabularyEntry] = []
    @ObservationIgnored private let fileURL: URL

    init(baseDirectory: URL) {
        fileURL = baseDirectory.appendingPathComponent("vocabulary.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode([VocabularyEntry].self, from: data) {
            entries = decoded
        }
    }

    /// Adds a term, or merges new variants into the existing entry with the same term.
    @discardableResult
    func add(term: String, variants: [String] = []) -> VocabularyEntry? {
        let cleanTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTerm.isEmpty else { return nil }
        let cleanVariants = Self.clean(variants, excluding: cleanTerm)
        if let index = entries.firstIndex(where: { $0.term.caseInsensitiveCompare(cleanTerm) == .orderedSame }) {
            entries[index].variants = Self.clean(entries[index].variants + cleanVariants, excluding: entries[index].term)
            save()
            return entries[index]
        }
        let entry = VocabularyEntry(term: cleanTerm, variants: cleanVariants)
        entries.insert(entry, at: 0)
        save()
        return entry
    }

    enum UpdateError: Error, Equatable { case emptyTerm, duplicate(String) }

    /// Saves an edited entry. Refuses an empty term or a term another entry already has.
    func update(_ entry: VocabularyEntry) throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        var updated = entry
        updated.term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.variants = Self.clean(entry.variants, excluding: updated.term)
        guard !updated.term.isEmpty else { throw UpdateError.emptyTerm }
        if let other = entries.first(where: { $0.id != entry.id && $0.term.caseInsensitiveCompare(updated.term) == .orderedSame }) {
            throw UpdateError.duplicate(other.term)
        }
        entries[index] = updated
        save()
    }

    /// Puts a deleted entry back (undo).
    func restore(_ entry: VocabularyEntry) {
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        entries.insert(entry, at: 0)
        save()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    var terms: [String] { entries.map(\.term) }

    /// Dictionary as plain text for LLM prompts: one line per term with its misheard forms.
    var promptContext: String {
        entries.map { entry in
            entry.variants.isEmpty
                ? "- \(entry.term)"
                : "- \(entry.term) (often misheard as: \(entry.variants.joined(separator: ", ")))"
        }
        .joined(separator: "\n")
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func clean(_ variants: [String], excluding term: String) -> [String] {
        var seen = Set<String>()
        return variants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { variant in
                let key = variant.lowercased()
                guard !variant.isEmpty, key != term.lowercased(), !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
    }
}

/// Replaces the dictionary's misheard forms with the correct terms. Pure and deterministic:
/// whole words only, case-insensitive, longest variant first, "[MM:SS] Speaker:" prefixes untouched.
enum VocabularyCorrection {
    static func apply(_ text: String, entries: [VocabularyEntry]) -> (text: String, replacements: Int) {
        let pairs = entries
            .flatMap { entry in entry.variants.map { (variant: $0, term: entry.term) } }
            .filter { !$0.variant.isEmpty }
            .sorted { $0.variant.count > $1.variant.count }
        guard !pairs.isEmpty else { return (text, 0) }

        var total = 0
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let (prefix, body) = splitPrefix(line)
            var corrected = body
            for pair in pairs {
                let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: pair.variant) + "(?![\\p{L}\\p{N}])"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let range = NSRange(corrected.startIndex..., in: corrected)
                let count = regex.numberOfMatches(in: corrected, range: range)
                guard count > 0 else { continue }
                total += count
                corrected = regex.stringByReplacingMatches(
                    in: corrected, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: pair.term))
            }
            return prefix + corrected
        }
        return (lines.joined(separator: "\n"), total)
    }

    /// "[01:23] Speaker 2: text" -> ("[01:23] Speaker 2: ", "text"); lines without a prefix keep all.
    private static func splitPrefix(_ line: String) -> (String, String) {
        guard line.hasPrefix("["),
              let bracket = line.firstIndex(of: "]"),
              let colon = line[bracket...].firstIndex(of: ":")
        else { return ("", line) }
        let bodyStart = line.index(after: colon)
        return (String(line[..<bodyStart]), String(line[bodyStart...]))
    }
}
