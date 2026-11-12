// Purpose: SpeakerPalette, one colour per speaker that stays the same across cards and the
//          transcript reader, plus initials for avatars.
// Dependencies: Sources/App/Transcription/SpeakerRenaming.swift (isGenerated),
//               Sources/App/Supporting/ThemeStore.swift (the active theme's eight speaker colours),
//               Sources/App/Transcription/TranscriptFormatting.swift (localSpeaker)
// Used by: Sources/App/Components/RecordingCardParts.swift (avatars, names, talk bar),
//          Sources/App/Views/TranscriptDetailView.swift (speaker chips and names)
// Notes: Design decision 2026-10-05 (card concept "Speaker Rail", user's pick). Eight colours
//        with light and dark variants, all at least 4.5:1 for text on the card background.
//        A name prefers the slot of a stable djb2 hash of its normalised form (never Swift's
//        hashValue, which is seeded per launch), so a person keeps their colour everywhere.
//        Inside one meeting a taken slot moves the later speaker (by first appearance) to the
//        next free one, so two people never share a colour. The user ("You" or their own name
//        from Settings, Audio) is graphite: colour always means someone else. Generated labels
//        ("Speaker 2") are neutral and drawn dashed: they are unfinished, not a person.

import AppKit
import SwiftUI

enum SpeakerPalette {

    /// How a speaker is drawn.
    enum Kind: Equatable {
        /// A named participant, with a palette slot 0..<slotCount.
        case person(slot: Int)
        /// The user: "You" or their own name.
        case owner
        /// A generated label such as "Speaker 2".
        case unnamed
    }

    static let slotCount = 8

    // Muted in dark mode (design review): the user must not be the brightest thing on the card.
    private static let ownerColor = (light: UInt32(0x1F2328), dark: UInt32(0xA8ADB4))
    private static let unnamedColor = (light: UInt32(0x6B7280), dark: UInt32(0x9CA3AF))

    // MARK: - Assignment

    /// Kinds for the speakers of one meeting, given in order of first appearance.
    static func assign(_ speakers: [String], ownName: String?) -> [String: Kind] {
        var result: [String: Kind] = [:]
        var taken = Set<Int>()
        for speaker in speakers where result[speaker] == nil {
            if isOwner(speaker, ownName: ownName) {
                result[speaker] = .owner
            } else if SpeakerRenaming.isGenerated(speaker) {
                result[speaker] = .unnamed
            } else {
                var slot = preferredSlot(for: speaker)
                // Probe to the next free slot; with more than eight people colours repeat.
                for _ in 0..<slotCount where taken.contains(slot) {
                    slot = (slot + 1) % slotCount
                }
                taken.insert(slot)
                result[speaker] = .person(slot: slot)
            }
        }
        return result
    }

    static func isOwner(_ speaker: String, ownName: String?) -> Bool {
        speaker == TranscriptFormatting.localSpeaker || (ownName.map { $0 == speaker } ?? false)
    }

    /// Stable slot for a name: djb2 over the trimmed, lowercased name without accents.
    static func preferredSlot(for name: String) -> Int {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let hash = normalized.unicodeScalars.reduce(into: UInt64(5381)) { partial, scalar in
            partial = (partial &* 33) &+ UInt64(scalar.value)
        }
        return Int(hash % UInt64(slotCount))
    }

    // MARK: - Colours

    /// The speaker's colour, for names, avatar fills and the talk bar. Slots come from the active
    /// theme (AppTheme.speakers); the user and generated labels look the same in every theme.
    @MainActor
    static func color(for kind: Kind) -> Color {
        switch kind {
        case .person(let slot):
            let speakers = ThemeStore.shared.palette.speakers
            return speakers.isEmpty ? .accentColor : speakers[slot % speakers.count]
        case .owner: return dynamic(ownerColor)
        case .unnamed: return dynamic(unnamedColor)
        }
    }

    /// Text on a filled avatar: white on the darker light-mode fills, near black on the brighter
    /// dark-mode fills.
    static let avatarText = dynamic((light: 0xFFFFFF, dark: 0x141414))

    private static func dynamic(_ pair: (light: UInt32, dark: UInt32)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return nsColor(isDark ? pair.dark : pair.light)
        })
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }

    // MARK: - Initials

    /// "Holger Wunsch" -> "HW", "anna" -> "A", "Speaker 2" -> "2", "You" -> the own name's
    /// initials when set, else "Y".
    static func initials(for speaker: String, ownName: String?) -> String {
        if speaker == TranscriptFormatting.localSpeaker, let ownName, !ownName.isEmpty {
            return initials(for: ownName, ownName: nil)
        }
        if SpeakerRenaming.isGenerated(speaker) {
            return speaker.split(separator: " ").last.map(String.init) ?? "?"
        }
        let words = speaker.split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        let letters = words.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}
