// Purpose: The action row of a session card — one Meeting Minutes button, one Transcribe button,
//          and an overflow menu holding everything that is not an everyday action.
// Dependencies: Sources/App/ViewModels/AppViewModel.swift,
//               Sources/App/Transcription/SpeakerRenaming.swift (isGenerated),
//               Sources/App/Components/SessionTranscribeButton.swift,
//               Sources/App/Views/SpeakerNamingSheet.swift
// RBAC: None.
// Dependents: Sources/App/Views/ProjectDetailView.swift (ProjectRecordingCard),
//             Sources/App/Views/AllTranscriptsView.swift (TranscriptCardWithProject)
// Notes: Both cards previously laid out every possible operation as an equally loud button — 18 of
//        them across six labelled sections, per card, always visible. This keeps the two actions
//        that are actually taken daily and demotes the rest into a menu.
//        "Meeting Minutes" is deliberately one button for generate-and-open: from the user's side
//        those were never two decisions, only two clicks. Existing minutes open, missing ones are
//        generated first.
//        With a transcript, the third visible button is "Name Speakers" (user decision 2026-10-02):
//        naming is the follow-up after reading, Retranscribe is a repair and sits in the menu.
//        Card redesign 2026-10-05: "Name N Speakers" is visible only while generated labels remain
//        (renaming named speakers moved into the menu); the menu also holds Rename (the title is
//        plain text now), Crop Audio and Restore Original Audio (the inline controls are gone).
//        "Update Summary" (formerly "Reprocess", user decision 2026-10-05) is the first menu entry once
//        a summary exists: it reruns Process, so speaker names given later reach the summary.
//        Destructive operations are grouped at the bottom of the menu, and deleting a session asks
//        first — it removes audio, transcript and minutes together and cannot be undone.
//        A meeting is first processed once it has a project (MeetingProcessingRule), so Summary is
//        disabled without one (the card's project menu is the action).

import SwiftUI

/// Everything the overflow menu needs to act on. Passed as one value so adding an entry does not
/// mean threading another closure through two card views.
struct SessionActionHandlers {
    var openTranscript: () -> Void
    var generateMinutes: () -> Void
    var openMinutes: () -> Void
    var deleteMinutes: () -> Void
    var extractTodos: () -> Void
    var extractKnowledge: () -> Void
    var deleteMic: () -> Void
    var deleteSpeaker: () -> Void
    var deleteTranscript: () -> Void
    var deleteSession: () -> Void
    /// Only meaningful inside a project view; nil elsewhere.
    var removeFromProject: (() -> Void)?
    /// Starts renaming the card's title in place.
    var rename: (() -> Void)? = nil
    /// Starts cropping in the card's waveform; nil while there is no waveform to crop.
    var cropAudio: (() -> Void)? = nil
    /// Restores the audio from before cropping; nil unless the session was cropped.
    var restoreAudio: (() -> Void)? = nil
}

struct SessionActionBar: View {
    @Environment(AppViewModel.self) private var viewModel

    let session: RecordingSession
    let hasMinutes: Bool
    let canGenerateMinutes: Bool
    let isGeneratingMinutes: Bool
    let canExtractTodos: Bool
    let isExtractingTodos: Bool
    let canExtractKnowledge: Bool
    let isExtractingKnowledge: Bool
    let hasMic: Bool
    let hasSystemAudio: Bool
    let handlers: SessionActionHandlers

    @State private var showSpeakerNaming = false
    @State private var showTranscript = false
    @State private var confirmDeleteSession = false

    private var hasTranscript: Bool {
        session.transcript?.text.isEmpty == false
    }

    var body: some View {
        HStack(spacing: 8) {
            // The primary buttons depend on how far the session has got; the menu does not. It is
            // always present, because it holds Delete Session — and a recording you decided not to
            // transcribe is exactly the one you want to delete.
            if hasTranscript {
                transcriptButton
                minutesButton
                // Visible only while generated labels remain; renaming named speakers is in the menu.
                if unnamedSpeakerCount > 0 {
                    nameSpeakersButton
                }
            } else if session.status == .recording || session.status == .liveTranscribing {
                // Nothing to offer while the microphone is open — transcribing needs a finished file.
                EmptyView()
            } else if session.status == .transcribing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                SessionTranscribeButton(session: session)
            }

            Spacer(minLength: 0)

            overflowMenu
        }
        .padding(.top, 4)
        .sheet(isPresented: $showSpeakerNaming) {
            SpeakerNamingSheet(session: session)
        }
        .sheet(isPresented: $showTranscript) {
            TranscriptDetailView(session: session)
        }
        .confirmationDialog(
            "Delete this session?",
            isPresented: $confirmDeleteSession,
            titleVisibility: .visible
        ) {
            Button("Delete Session", role: .destructive) { handlers.deleteSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The recording, its transcript and its meeting minutes are removed. This cannot be undone."
            )
        }
    }

    // MARK: - Primary

    /// Reading the transcript is the single most common thing to do with a finished recording, so it
    /// is the first button — not a menu entry, and not a handoff to TextEdit.
    private var transcriptButton: some View {
        Button {
            showTranscript = true
        } label: {
            Label("Transcript", systemImage: "text.alignleft")
        }
        // Not prominent (card redesign 2026-10-05): a filled button on every card is noise; only
        // an open next step (naming speakers) is tinted.
        .buttonStyle(.bordered)
        .help("Read, search, edit and copy the transcript")
    }

    /// Generate-and-open in one control: minutes that exist open, minutes that do not are generated
    /// first. The distinction is bookkeeping the app can do on its own.
    private var minutesButton: some View {
        Button {
            hasMinutes ? handlers.openMinutes() : handlers.generateMinutes()
        } label: {
            if isGeneratingMinutes {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Processing\u{2026}")
                }
            } else {
                Label("Summary", systemImage: "doc.text")
            }
        }
        .buttonStyle(.bordered)
        .disabled(isGeneratingMinutes || (!hasMinutes && (!canGenerateMinutes || processingHold == .waitForProject)))
        .help(minutesHelp)
    }

    /// Without a summary: no project yet (the card's project menu starts processing). See
    /// MeetingProcessingRule.
    private var processingHold: MeetingProcessingRule.Decision? {
        hasMinutes ? nil : viewModel.processingHold(for: session)
    }

    private var minutesHelp: String {
        if hasMinutes { return "Open the meeting minutes" }
        switch processingHold {
        case .waitForProject: return "Assign a project to process this meeting"
        default: return "Write meeting minutes from the transcript"
        }
    }

    private var unnamedSpeakerCount: Int {
        viewModel.nameableSpeakers(for: session).filter {
            $0.name == nil && SpeakerRenaming.isGenerated($0.label)
        }.count
    }

    /// Naming speakers is something done per meeting after reading it, retranscribing is a repair:
    /// so naming gets the visible slot and Retranscribe lives in the menu. Tinted while generated
    /// labels remain, matching the button in the transcript reader.
    private var nameSpeakersButton: some View {
        Button {
            showSpeakerNaming = true
        } label: {
            Label(
                unnamedSpeakerCount == 1 ? "Name 1 Speaker" : "Name \(unnamedSpeakerCount) Speakers",
                systemImage: "person.2.badge.gearshape")
        }
        .buttonStyle(.bordered)
        .tint(.accentColor)
        .help("\(unnamedSpeakerCount) speakers still have a generated label: listen and name them")
    }

    /// Same action as the Transcribe button, one level down: the configured engine, with the
    /// per-run language override as the choice.
    private var retranscribeMenu: some View {
        Menu {
            Section("With \(viewModel.configuredTranscriptionEngineName)") {
                ForEach(AppViewModel.LanguageOption.allCases) { option in
                    Button(option.label) {
                        viewModel.transcribeWithConfiguredEngine(sessionID: session.id, language: option)
                    }
                }
            }
            if let note = viewModel.transcriptionEngineFallbackNote {
                Text(note)
            }
        } label: {
            Label("Retranscribe", systemImage: "waveform")
        }
        .disabled(session.status.isActive)
    }

    // MARK: - Overflow

    private var overflowMenu: some View {
        Menu {
            // First entry: rewriting the summary after the transcript changed (speakers named,
            // transcript edited) is the most common reason to open this menu on a processed meeting.
            if hasMinutes {
                Button {
                    handlers.generateMinutes()
                } label: {
                    Label("Update Summary", systemImage: "arrow.clockwise")
                }
                .disabled(!canGenerateMinutes || isGeneratingMinutes)
                Divider()
            }

            if let rename = handlers.rename {
                Button {
                    rename()
                } label: {
                    Label("Rename\u{2026}", systemImage: "pencil")
                }
            }

            if hasTranscript {
                if unnamedSpeakerCount == 0, !viewModel.nameableSpeakers(for: session).isEmpty {
                    Button {
                        showSpeakerNaming = true
                    } label: {
                        Label("Rename Speakers\u{2026}", systemImage: "person.2.badge.gearshape")
                    }
                }

                Button {
                    handlers.openTranscript()
                } label: {
                    Label("Open Transcript File", systemImage: "doc.richtext")
                }

                retranscribeMenu

                if viewModel.isCleaningUpTranscript(session) {
                    Label("Polishing…", systemImage: "hourglass")
                } else {
                    Button {
                        Task { await viewModel.cleanUpTranscript(for: session) }
                    } label: {
                        Label("Polish with AI", systemImage: "wand.and.stars")
                    }
                    if viewModel.canRevertTranscriptCleanup(session) {
                        Button {
                            viewModel.revertTranscriptCleanup(for: session)
                        } label: {
                            Label("Undo Polish", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            }

            if hasMinutes {
                Divider()
                Button {
                    handlers.extractTodos()
                } label: {
                    Label(
                        isExtractingTodos ? "Extracting todos…" : "Extract Todos",
                        systemImage: "checklist")
                }
                .disabled(!canExtractTodos || isExtractingTodos)

                Button {
                    handlers.extractKnowledge()
                } label: {
                    Label(
                        isExtractingKnowledge ? "Extracting knowledge…" : "Extract Knowledge",
                        systemImage: "lightbulb")
                }
                .disabled(!canExtractKnowledge || isExtractingKnowledge)
            }

            Divider()

            if handlers.cropAudio != nil || handlers.restoreAudio != nil {
                if let cropAudio = handlers.cropAudio {
                    Button {
                        cropAudio()
                    } label: {
                        Label("Crop Audio\u{2026}", systemImage: "scissors")
                    }
                    .disabled(session.status.isActive)
                }
                if let restoreAudio = handlers.restoreAudio {
                    Button {
                        restoreAudio()
                    } label: {
                        Label("Restore Original Audio", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(session.status.isActive)
                }
                Divider()
            }

            if let removeFromProject = handlers.removeFromProject {
                Button {
                    removeFromProject()
                } label: {
                    Label("Remove from Project", systemImage: "folder.badge.minus")
                }
            }

            // Deleting individual files is a storage decision, not an everyday one — kept reachable
            // but out of the way, one level down.
            Menu {
                Button("Delete Microphone Audio", role: .destructive, action: handlers.deleteMic)
                    .disabled(!hasMic)
                Button("Delete Meeting Audio", role: .destructive, action: handlers.deleteSpeaker)
                    .disabled(!hasSystemAudio)
                Button("Delete Transcript", role: .destructive, action: handlers.deleteTranscript)
                    .disabled(!hasTranscript)
                Button("Delete Minutes", role: .destructive, action: handlers.deleteMinutes)
                    .disabled(!hasMinutes)
            } label: {
                Label("Delete Individual Files", systemImage: "internaldrive")
            }

            // Deleting a session whose files are still being written would leave the recorder
            // pointing at nothing, so it waits until the session is at rest.
            Button(role: .destructive) {
                confirmDeleteSession = true
            } label: {
                Label("Delete Session…", systemImage: "trash")
            }
            .disabled(session.status.isActive)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More actions")
    }
}
