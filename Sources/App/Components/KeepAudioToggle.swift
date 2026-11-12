// Purpose: AudioRetentionChip, the recording card's audio retention control: when the audio will
//          be deleted, and a click to keep it.
// Dependencies: Sources/App/Services/AudioRetentionPolicy.swift,
//               Sources/App/ViewModels/AppViewModel.swift (setKeepAudio)
// RBAC: None.
// Dependents: Sources/App/Components/RecordingCardParts.swift (meta line of both recording cards)
// Notes: Placement and shape were the user's call: a plain checkbox, bottom right of the card.
//        It renders only while the session still has audio; once the audio is gone there is
//        nothing to keep. The countdown caption sits left of the checkbox so the consequence of
//        leaving it unticked is visible without a tooltip; it turns orange in the last 2 days.
//        No caption while the recording has no transcript, because the policy never purges then;
//        the tooltip says so. Wording and the tooltip came out of a design review on 2026-10-02.
//        2026-10-05 card redesign (user's pick): the checkbox became a small chip "Audio 14d" in
//        the meta line; a click toggles Keep (then "Audio kept" with a pin). Orange in the last
//        2 days, same tooltip rule. The file keeps its old name (no renames).

import SwiftUI

/// The card's compact retention control: "◷ Audio 14d", or "Audio kept" with a pin once kept.
struct AudioRetentionChip: View {
    @Environment(AppViewModel.self) private var viewModel
    let session: RecordingSession

    var body: some View {
        if AudioRetentionPolicy.hasAudio(session) {
            let kept = session.keepAudio == true
            let days = AudioRetentionPolicy.daysUntilDeletion(for: session)
            Button {
                viewModel.setKeepAudio(!kept, for: session.id)
            } label: {
                Label(label(kept: kept, days: days), systemImage: kept ? "pin.fill" : "clock")
                    .font(.caption)
                    .foregroundStyle(color(kept: kept, days: days))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help(helpText(kept: kept))
        }
    }

    private func label(kept: Bool, days: Int?) -> String {
        if kept { return "Audio kept" }
        guard let days else { return "Audio" }
        switch days {
        case 0: return "Audio today"
        default: return "Audio \(days)d"
        }
    }

    private func color(kept: Bool, days: Int?) -> AnyShapeStyle {
        if !kept, let days, days <= 2 { return AnyShapeStyle(.orange) }
        return AnyShapeStyle(.secondary)
    }

    private func helpText(kept: Bool) -> String {
        let rule = "Audio is deleted \(AudioRetentionPolicy.retentionDays) days after recording. "
            + "Transcript and summary are always kept."
        if kept { return "Audio is kept. Click to delete it with the others after \(AudioRetentionPolicy.retentionDays) days." }
        guard let text = session.transcript?.text, !text.isEmpty else {
            return rule + " Not deleted while there is no transcript. Click to keep it."
        }
        return rule + " Click to keep it."
    }
}
