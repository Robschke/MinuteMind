// Purpose: Persists the voice library — every person the user has ever named in the speaker-naming
//          sheet, with the embedding that lets later recordings recognise them automatically.
// Dependencies: Sources/App/Models/KnownVoice.swift, Foundation
// Used by: Sources/App/ViewModels/AppViewModel.swift (voiceDirectory property),
//          Sources/App/Views/SpeakerNamingSheet.swift (suggestions),
//          Sources/App/Views/VoiceLibrarySettingsView.swift (rename/delete)
// Notes: Stored as `voices.json` next to the other Application Support files. Matching a name that
//        already exists merges into that voice rather than creating a duplicate, so "Anna" stays one
//        person even when she is named again from a different meeting.
//        Only called from @MainActor context, so no locking is needed.

import Foundation

final class VoiceDirectoryStore {

    private let fileURL: URL
    private(set) var voices: [KnownVoice]

    init(baseDirectory: URL) {
        self.fileURL = baseDirectory.appendingPathComponent("voices.json")
        self.voices = Self.load(from: fileURL)
    }

    // MARK: - Lookup

    /// The known voice closest to `embedding`, when it is within `VoiceEmbedding.matchThreshold`.
    /// Returns the distance too, so callers can show how confident the match was.
    func match(_ embedding: [Float]) -> (voice: KnownVoice, distance: Float)? {
        guard VoiceEmbedding.isUsable(embedding) else { return nil }

        let scored = voices
            .map { (voice: $0, distance: VoiceEmbedding.distance($0.embedding, embedding)) }
            .min { $0.distance < $1.distance }

        guard let scored, scored.distance <= VoiceEmbedding.matchThreshold else { return nil }
        return scored
    }

    func voice(id: UUID) -> KnownVoice? {
        voices.first { $0.id == id }
    }

    /// All known names, for the naming sheet's suggestion menu.
    var names: [String] {
        voices.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Learning

    /// Records that `embedding` belongs to `name`, merging into the existing voice when that name
    /// is already known. Returns the stored voice, or nil when the embedding was unusable.
    @discardableResult
    func learn(name: String, embedding: [Float], spokenSeconds: TimeInterval = 0) -> KnownVoice? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, VoiceEmbedding.isUsable(embedding) else { return nil }

        if let index = voices.firstIndex(where: {
            $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            voices[index].merge(embedding, spokenSeconds: spokenSeconds)
            save()
            return voices[index]
        }

        let voice = KnownVoice(
            name: trimmed, embedding: embedding, totalSpokenSeconds: max(0, spokenSeconds))
        voices.append(voice)
        save()
        return voice
    }

    // MARK: - Management

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = voices.firstIndex(where: { $0.id == id }) else { return }
        voices[index].name = trimmed
        voices[index].updatedAt = Date()
        save()
    }

    func delete(_ id: UUID) {
        voices.removeAll { $0.id == id }
        save()
    }

    // MARK: - Persistence

    private static func load(from fileURL: URL) -> [KnownVoice] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([KnownVoice].self, from: data)) ?? []
    }

    /// Failures are logged rather than thrown: losing a learned voice is an annoyance, not a reason
    /// to fail the transcription or the rename the user just asked for.
    private func save() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(voices).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("VoiceDirectoryStore: save failed — \(error.localizedDescription)")
        }
    }
}
