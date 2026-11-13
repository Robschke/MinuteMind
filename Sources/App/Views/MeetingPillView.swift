// Purpose: MeetingPillView, the SwiftUI content of the floating meeting pill: the "meeting
//          detected" card, the ignored-meeting ring, the one-time consent notice, the recording
//          capsule, the "meeting over?" question and the "saved, process now?" card, plus the
//          idle bar and the quick dictation capsule.
// Dependencies: Sources/App/Supporting/MeetingPillController.swift (MeetingPillModel, PillMeeting)
// Used by: Sources/App/Supporting/MeetingPillController.swift (hosted in the pill panel)
// Notes: Visual system after design review 1 (scratchpad design-review-1.md, items 1.1 to 1.21):
//        - Neutral light glass: .popover material with a white 0.55 (dark: black 0.20) wash so the
//          wallpaper does not tint it; one soft shadow pair; the panel itself has no shadow.
//        - Red (#D7302A) means capture only (recording dot, Record, Stop). Process uses the accent
//          color. Neutral buttons: primary 0.08 / 0.12 hover / 0.18 pressed, 24 pt tall.
//        - Nothing below 11 pt; second lines are primary at 0.62 opacity.
//        - An ignored meeting becomes a hollow record ring (not a red dot, which would read as
//          "recording"); hovering it reveals "Record <title>".
//        - The recording capsule reveals Open and Stop (Stop last) after a short hover intent.
//        - Countdowns on the saved card are a draining 2 pt line, not changing button text.
//        - Decorations are hidden from VoiceOver; the capsule exposes Stop/Open as actions.
//        - Idle bar and dictation capsule (2026-10-04): the idle bar is quiet glass with a light
//          shadow; the dictation capsule matches the recording capsule (32 pt, 16 pt radius) and
//          shows only the waveform, no text; it ends by shrinking into the idle bar.
//        - Quick recordings add a quiet "fn to stop" after the timer (hidden while Stop shows).
//        - Companion mode (2026-10-13, the desktop creature replaces the pill): the same cards open
//          beside the creature, aligned to the edge facing it. Instead of the idle bar, hovering the
//          creature opens a small card with Record, Claude, Open MinuteMind, the dictation hint and
//          the Claude sessions that need the user; Claude notices are a one-row card with Show.
//          Beside the companion every card takes the pixel finish (PillPixelStyle.swift): stepped
//          corners, crisp border, hard shadow, blocky buttons, square dot, block meter, and a
//          block waveform in the dictation capsule (2026-10-13).
//        - The companion card's clipboard button swaps the card for the Clipboard list (the last
//          20 copied texts and images, ClipboardHistory; images get a thumbnail): a row click
//          copies it again and closes the card,
//          Insert on hover pastes it at the cursor; a chevron leads back to the buttons. The
//          ignored-meeting and recording cards carry the same tool row (Claude, Claude windows,
//          Clipboard) underneath, so the companion offers them in every quiet state.
//        - Shared Projects: the saved card asks whether to publish with the card's own pieces
//          (second line, a primary-coloured question line, a button row like the project row):
//          Publish is the constructive button, Keep private neutral, Change the wheel button.
//        UI strings are English like the rest of the app.

import AppKit
import SwiftUI

enum PillStyle {
    static let captureRed = Color(red: 0.84, green: 0.19, blue: 0.16)
    /// Claude tasks only: the theme accent, so the mark follows MinuteMind's own look.
    @MainActor static var claude: Color { DesignSystem.Colors.accent }
    static let secondaryText = Color.primary.opacity(0.62)
    static let titleWidth: CGFloat = 240
}

struct MeetingPillView: View {
    @Bindable var model: MeetingPillModel
    var onSizeChange: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Distance from the bottom of the visible screen area to the bottom edge of the pill.
    static let bottomClearance: CGFloat = 40
    /// The same for the idle bar and a dictation started from it: lower, since the bar is always
    /// there. Equal to the bottom inset, so the panel ends exactly at the visible frame.
    static let idleBottomClearance: CGFloat = 24

    /// Transparent margin around the content for its shadow. The idle bar has a tiny shadow, so
    /// its top and side margins are small: the panel catches clicks, and a permanent bar must not
    /// leave a large dead zone over the apps above it. The bottom margin never changes, so the
    /// panel's anchor stays put and outgoing content does not jump while it fades.
    static func insets(for model: MeetingPillModel) -> EdgeInsets {
        if !model.companionMode, model.dictation == nil, model.state == .hidden, !model.idleExpanded {
            return EdgeInsets(top: 6, leading: 8, bottom: 24, trailing: 8)
        }
        return EdgeInsets(top: 16, leading: 20, bottom: 24, trailing: 20)
    }

    var body: some View {
        content
            .fixedSize()
            .padding(Self.insets(for: model))
            // The panel shrinks only after a transition; until then smaller content sits at the
            // bottom of the larger panel instead of floating in its middle and then dropping.
            // Beside the companion the content hugs the edge facing the creature instead.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: contentAlignment)
            .environment(\.pillPixelStyle, model.companionMode)
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0.15), value: model.displayKind)
            .animation(.spring(duration: 0.3, bounce: 0.1), value: model.showsRecordingControls)
            .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.1), value: model.idleExpanded)
            .onChange(of: model.displayKind) { _, _ in DispatchQueue.main.async(execute: onSizeChange) }
            .onChange(of: model.showsRecordingControls) { _, _ in DispatchQueue.main.async(execute: onSizeChange) }
            .onChange(of: model.dotExpanded) { _, _ in DispatchQueue.main.async(execute: onSizeChange) }
            .onChange(of: model.idleExpanded) { _, _ in DispatchQueue.main.async(execute: onSizeChange) }
            .onChange(of: model.showsClipboard) { _, _ in DispatchQueue.main.async(execute: onSizeChange) }
            .onChange(of: model.dictation) { _, _ in DispatchQueue.main.async(execute: onSizeChange) }
            .onChange(of: model.dictationMicStalled) { _, _ in DispatchQueue.main.async(execute: onSizeChange) }
            .onChange(of: model.notice) { _, _ in DispatchQueue.main.async(execute: onSizeChange) }
            .onChange(of: model.projectWheel?.committed) { _, _ in DispatchQueue.main.async(execute: onSizeChange) }
            .onChange(of: model.projectWheel == nil) { _, _ in DispatchQueue.main.async(execute: onSizeChange) }
    }

    private var contentAlignment: Alignment {
        guard model.companionMode else { return .bottom }
        return model.opensLeft ? .trailing : .leading
    }

    @ViewBuilder
    private var content: some View {
        if let dictation = model.dictation {
            dictationCapsule(dictation).transition(.asymmetric(insertion: appear, removal: shrinkAway))
        } else if let card = model.projectWheel {
            projectWheelCard(card).transition(appear)
        } else if let card = model.assistant {
            assistantCard(card).transition(appear)
        } else if model.companionMode {
            companionContent
        } else {
            meetingContent
        }
    }

    /// Beside the companion: hover cards for the quiet states, a notice when one is up, and the
    /// usual cards for everything that needs the user.
    @ViewBuilder
    private var companionContent: some View {
        switch model.state {
        case .hidden:
            if model.idleExpanded, model.showsClipboard {
                clipboardCard.transition(appear)
            } else if model.idleExpanded {
                companionCard.transition(appear)
            } else if let notice = model.notice {
                noticeCard(notice).transition(appear)
            } else if model.showsCoach {
                coachCard.transition(appear)
            }
        case .dot(let meeting):
            if model.dotExpanded, model.showsClipboard {
                clipboardCard.transition(appear)
            } else if model.dotExpanded {
                withAttentionRows(ring(meeting), tools: .withOpenApp).transition(appear)
            } else if let notice = model.notice {
                noticeCard(notice).transition(appear)
            }
        case .recording:
            if model.showsRecordingControls, model.showsClipboard {
                clipboardCard.transition(appear)
            } else if model.showsRecordingControls || model.hintFlashing || model.notice == nil {
                // Sessions that need the user stay reachable during a recording; the capsule
                // has its own Open button, so the tool row leaves it out.
                withAttentionRows(
                    recordingCapsule, show: model.showsRecordingControls,
                    tools: model.showsRecordingControls ? .withoutOpenApp : nil
                ).transition(appear)
            } else if let notice = model.notice {
                noticeCard(notice).transition(appear)
            }
        default:
            meetingContent
        }
    }

    /// Which tool row goes under a card: the busy states (ignored meeting, recording) keep
    /// Claude, the Claude windows and the Clipboard one click away, as the idle card does.
    enum ToolRow { case withOpenApp, withoutOpenApp }

    /// The Claude sessions that need the user, in a small card under another card, and the
    /// companion's tool row when `tools` is set.
    private func withAttentionRows(_ content: some View, show: Bool = true, tools: ToolRow? = nil) -> some View {
        VStack(alignment: model.opensLeft ? .trailing : .leading, spacing: 6) {
            content
            if let tools {
                HStack(spacing: 6) { toolButtons(openApp: tools == .withOpenApp) }
                    .padding(8)
                    .glass(cornerRadius: 14)
                    .onHover { model.hoverCurrentCard($0) }
            }
            if show, !model.attentionRows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.attentionRows.prefix(4)) { row in sessionRow(row) }
                }
                .padding(10)
                .glass(cornerRadius: 14)
                .onHover { model.isHovering = $0 }
            }
        }
    }

    /// Shown once, the first time the companion appears.
    private var coachCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hi, I\u{2019}m your MinuteMind companion")
                .font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 3) {
                Text("Drag me anywhere. Click for options.")
                Text("Double click brings your Claude windows here.")
                Text("Right click for more, including Hide.")
            }
            .font(.system(size: 11))
            .foregroundStyle(PillStyle.secondaryText)
            HStack {
                Spacer()
                Button("Got It", action: model.dismissCoach).buttonStyle(PillButtonStyle(.constructive))
            }
        }
        .frame(width: 250, alignment: .leading)
        .padding(12)
        .glass(cornerRadius: 14)
        .onHover { model.isHovering = $0 }
    }

    @ViewBuilder
    private var meetingContent: some View {
        switch model.state {
        case .hidden:
            if model.idleBarEnabled {
                idleBar.transition(.opacity)
            }
        case .detected(let meeting):
            detectedCard(meeting).transition(appear)
        case .dot(let meeting):
            ring(meeting).transition(appear)
        case .consent(let meeting):
            consentCard(meeting).transition(appear)
        case .recording:
            recordingCapsule.transition(appear)
        case .confirmStop(let signal):
            confirmStopCard(signal).transition(appear)
        case .saved(let sessionID, let title, let minutes, let next, _):
            savedCard(sessionID: sessionID, title: title, minutes: minutes, next: next).transition(appear)
        }
    }

    /// Dictation ends by collapsing toward the idle bar below it.
    private var shrinkAway: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.25, anchor: .bottom))
    }

    private var appear: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 10)).combined(with: .scale(scale: 0.97))
    }

    // MARK: - States

    /// The quiet bar shown when nothing is going on. Hovering opens it to the dictation hint and a
    /// Record button, the two things this pill can start.
    private var idleBar: some View {
        Group {
            if model.idleExpanded {
                HStack(spacing: 10) {
                    if let hint = model.dictationHint {
                        HStack(spacing: 6) {
                            Image(systemName: "mic")
                                .font(.system(size: 11, weight: .medium))
                                .accessibilityHidden(true)
                            Text(hint)
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(PillStyle.secondaryText)
                    }
                    Button(action: model.recordNow) {
                        HStack(spacing: 5) {
                            Image(systemName: "record.circle").font(.system(size: 11, weight: .semibold))
                            Text("Record")
                        }
                    }
                    .buttonStyle(PillButtonStyle(.neutral))
                    .help("Record a meeting now")
                }
                .padding(.leading, model.dictationHint == nil ? 4 : 12)
                .padding(.trailing, 4)
                .frame(height: 32)
                .glass(cornerRadius: 16)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
            } else {
                // A solid hairline bar reads on any background, unlike glass at this size; the
                // hover target is much larger than the bar so it is easy to find.
                // Fixed mid gray, not .primary: the system appearance says nothing about the app
                // window behind the bar, and a dark-mode white bar vanished on light windows.
                Capsule()
                    .fill(Color(white: 0.5).opacity(0.75))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
                    .frame(width: 44, height: 6)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .frame(width: 96, height: 24, alignment: .bottom)
                    .contentShape(Rectangle())
                    .transition(.opacity)
            }
        }
        .onHover { model.hoverIdle($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MinuteMind")
        .accessibilityAction(named: "Record Meeting", model.recordNow)
    }

    /// The voice assistant's result: an answer to copy or insert, what it did, a question to
    /// answer (typed, or dictated with the fn key), or what went wrong.
    private func assistantCard(_ card: AssistantCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                switch card {
                case .done: sessionIcon(.done)
                case .failed: sessionIcon(.error)
                case .answer, .ask: ClaudeMark(working: false)
                }
                VStack(alignment: .leading, spacing: 3) {
                    switch card {
                    case .answer(let text):
                        ScrollView {
                            Text(text).font(.system(size: 12)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160)
                    case .done(let summary, let details):
                        Text(summary).font(.system(size: 13, weight: .semibold))
                        if !details.isEmpty {
                            Text(details).font(.system(size: 11)).foregroundStyle(PillStyle.secondaryText).lineLimit(5)
                        }
                    case .ask(let question):
                        Text(question).font(.system(size: 13, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        TextField("Your answer", text: $model.askDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(model.assistantSend)
                        Text("Type, or hold fn and speak")
                            .font(.system(size: 11)).foregroundStyle(PillStyle.secondaryText)
                    case .failed(let message):
                        Text(message).font(.system(size: 12)).foregroundStyle(PillStyle.secondaryText).lineLimit(4)
                    }
                }
                .frame(width: 280, alignment: .leading)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                switch card {
                case .answer:
                    Button("Close", action: model.assistantDismiss).buttonStyle(PillButtonStyle(.neutral))
                    Button("Copy", action: model.assistantCopy).buttonStyle(PillButtonStyle(.neutral))
                    Button("Insert", action: model.assistantInsert).buttonStyle(PillButtonStyle(.constructive))
                case .ask:
                    Button("Cancel", action: model.assistantCancel).buttonStyle(PillButtonStyle(.neutral))
                    Button("Send", action: model.assistantSend).buttonStyle(PillButtonStyle(.constructive))
                        .disabled(model.askDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                case .done, .failed:
                    Button("OK", action: model.assistantDismiss).buttonStyle(PillButtonStyle(.neutral))
                }
            }
        }
        .padding(12)
        .glass(cornerRadius: 14)
        .onHover { model.isHovering = $0 }
        .accessibilityElement(children: .contain)
    }

    /// The project list scrolled over the companion while recording: the selection in the middle
    /// with its colour, two neighbours above and below fading out (the list wraps, so they are
    /// always there with three or more entries), and a line that drains until the selection is
    /// taken. Once taken it shrinks to one confirming row. Fixed height while scrolling, so the
    /// panel does not jump with every step.
    private func projectWheelCard(_ card: ProjectWheelCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if card.committed, let item = card.wheel.selected {
                HStack(spacing: 8) {
                    Image(systemName: model.companionMode ? "checkmark.square.fill" : "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(item.colorHex.map { Color(hex: $0) } ?? PillStyle.secondaryText)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.isLater ? "Later" : item.projectID == nil ? "No project" : "Filed to \(item.name)")
                            .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(Self.wheelConfirmation(item))
                            .font(.system(size: 11)).foregroundStyle(PillStyle.secondaryText)
                    }
                }
                .frame(width: 200, alignment: .leading)
            } else {
                Text("Project for this recording")
                    .font(.system(size: 11)).foregroundStyle(PillStyle.secondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(-2...2, id: \.self) { offset in
                        wheelRow(card.wheel, offset: offset)
                    }
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: card.wheel.index)
                if let commitAt = card.commitAt {
                    TimelineView(.animation) { context in
                        let left = max(0, commitAt.timeIntervalSince(context.date)) / max(card.commitDelay, 0.1)
                        GeometryReader { proxy in
                            Rectangle().fill(Color.primary.opacity(0.10))
                                .overlay(alignment: .leading) {
                                    Rectangle().fill(Color.accentColor).frame(width: proxy.size.width * left)
                                }
                        }
                        .frame(height: 2)
                    }
                    .accessibilityHidden(true)
                }
                if !card.hint.isEmpty {
                    Text(card.hint)
                        .font(.system(size: 11)).foregroundStyle(PillStyle.secondaryText)
                }
            }
        }
        .padding(12)
        .frame(width: 224, alignment: .leading)
        .glass(cornerRadius: 14)
        .onHover { model.isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.committed
            ? "Recording files to \(card.wheel.selected?.name ?? "")"
            : "Project for this recording: \(card.wheel.selected?.name ?? "")")
    }

    /// One row of the wheel; a click takes it at once. The starting project says "current", so
    /// the user sees what leaving it alone keeps. Square dot and selection beside the companion.
    @ViewBuilder
    private func wheelRow(_ wheel: ProjectWheel, offset: Int) -> some View {
        let count = wheel.items.count
        // Neighbours only when the list is long enough that they are not the selection itself.
        let shows = count > 0 && (offset == 0 || count > 2 * abs(offset))
        let index = count == 0 ? 0 : ((wheel.index + offset) % count + count) % count
        let item = count == 0 ? nil : wheel.items[index]
        let pixel = model.companionMode
        Button {
            model.projectWheelPick(index)
        } label: {
            HStack(spacing: 8) {
                let dot = item?.colorHex.map { Color(hex: $0) } ?? Color.primary.opacity(0.25)
                Group {
                    if pixel { Rectangle().fill(dot) } else { Circle().fill(dot) }
                }
                .frame(width: 8, height: 8)
                Text(item?.name ?? "")
                    .font(.system(size: offset == 0 ? 13 : 12, weight: offset == 0 ? .semibold : .regular))
                    .lineLimit(1)
                if let item, item.isStarred {
                    StarredProjectMark(avatar: item.markAvatar, bodyColor: item.markColor)
                }
                Spacer(minLength: 0)
                if index == wheel.startIndex {
                    Text("current").font(.system(size: 11)).foregroundStyle(PillStyle.secondaryText)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: offset == 0 ? 24 : 18)
            .background(
                RoundedRectangle(cornerRadius: pixel ? 0 : 6).fill(Color.primary.opacity(offset == 0 ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!shows)
        .opacity(shows ? (offset == 0 ? 1 : abs(offset) == 1 ? 0.55 : 0.25) : 0)
        .accessibilityHidden(!shows)
    }

    /// The confirmation's second line: where the summary goes, or that the Inbox asks later.
    private static func wheelConfirmation(_ item: ProjectWheel.Item) -> String {
        if item.isLater { return "It waits in the Inbox" }
        switch item.projectID {
        case nil: return "Choose one later in the Inbox"
        case ProjectRepositoryService.generalProjectID: return "Summary and knowledge go to General"
        default: return "Summary and knowledge go here"
        }
    }

    /// The companion's hover card: what the idle bar offered, plus Claude.
    private var companionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button(action: model.recordNow) {
                    HStack(spacing: 5) {
                        Image(systemName: "record.circle").font(.system(size: 11, weight: .semibold))
                        Text("Record")
                    }
                }
                .buttonStyle(PillButtonStyle(.neutral))
                .help("Record a meeting now")
                toolButtons(openApp: true)
            }
            if let hint = model.dictationHint {
                HStack(spacing: 6) {
                    Image(systemName: "mic")
                        .font(.system(size: 11, weight: .medium))
                        .accessibilityHidden(true)
                    Text(hint).font(.system(size: 12))
                }
                .foregroundStyle(PillStyle.secondaryText)
            }
            if !model.attentionRows.isEmpty {
                Divider()
                ForEach(model.attentionRows.prefix(4)) { row in
                    sessionRow(row)
                }
            }
        }
        .padding(10)
        .glass(cornerRadius: 14)
        .onHover { model.hoverIdle($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MinuteMind")
    }

    /// Claude, Bring Claude Windows Here, Clipboard and (optionally) Open MinuteMind, shared by the
    /// idle card and the tool row under the busy states' cards.
    @ViewBuilder
    private func toolButtons(openApp: Bool) -> some View {
        Button(action: model.openClaude) {
            HStack(spacing: 5) {
                Image(systemName: "sparkle").font(.system(size: 11, weight: .semibold))
                Text("Claude")
            }
        }
        .buttonStyle(PillButtonStyle(.neutral))
        .help("Open Claude in the General workspace")
        Button(action: model.summonClaude) {
            Image(systemName: "rectangle.stack").frame(minWidth: 14)
        }
        .buttonStyle(PillButtonStyle(.neutral))
        .help("Bring all Claude windows here (or double click the creature)")
        .accessibilityLabel("Bring Claude Windows Here")
        Button(action: model.openClipboard) {
            Image(systemName: "doc.on.clipboard").frame(minWidth: 14)
        }
        .buttonStyle(PillButtonStyle(.neutral))
        .help("Clipboard: the last \(ClipboardHistory.limit) things you copied")
        .accessibilityLabel("Clipboard")
        if openApp {
            Button(action: model.openApp) {
                Image(systemName: "arrow.up.forward.app").frame(minWidth: 14)
            }
            .buttonStyle(PillButtonStyle(.neutral))
            .help("Open MinuteMind")
            .accessibilityLabel("Open MinuteMind")
        }
    }

    /// The companion card's Clipboard list: a click on a row copies it again, Insert (on hover)
    /// pastes it where the user is typing. Newest first, one line each, scrolls past eight rows.
    private var clipboardCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // The whole title leads back, a bigger target than a lone chevron.
                Button {
                    model.showsClipboard = false
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Clipboard").font(.system(size: 13, weight: .semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back")
                .accessibilityLabel("Back to the companion card")
                Spacer(minLength: 0)
                if !model.clipboardItems.isEmpty {
                    Text("Click to copy")
                        .font(.system(size: 11))
                        .foregroundStyle(PillStyle.secondaryText)
                }
            }
            if model.clipboardItems.isEmpty {
                Text("Text and screenshots you copy show up here. Kept until MinuteMind quits.")
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.system(size: 12))
                    .foregroundStyle(PillStyle.secondaryText)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.clipboardItems) { item in
                            ClipboardRow(
                                item: item,
                                pixel: model.companionMode,
                                copy: { model.clipboardCopy(item) },
                                insert: { model.clipboardInsert(item) })
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(height: min(CGFloat(model.clipboardItems.count), 8) * ClipboardRow.height
                    + CGFloat(max(min(model.clipboardItems.count, 8) - 1, 0)) * 2)
            }
        }
        .frame(width: 280, alignment: .leading)
        .padding(10)
        .glass(cornerRadius: 14)
        .onHover { model.hoverCurrentCard($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clipboard")
    }

    /// A session that needs the user; a click on its text opens its chat card (when it asks
    /// something the card can show), Show goes to the session.
    private func sessionRow(_ row: CompanionSessionRow) -> some View {
        HStack(spacing: 8) {
            Button {
                if row.request != nil { model.openSessionChat(row) } else { model.showSession(row.id) }
            } label: {
                HStack(spacing: 8) {
                    sessionIcon(row.kind)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.headline).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text("\(row.project) \u{00B7} \(row.session)")
                            .font(.system(size: 11))
                            .foregroundStyle(PillStyle.secondaryText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 200, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(row.request != nil ? "Answer here" : "Show the session")
            Spacer(minLength: 8)
            Button("Show") { model.showSession(row.id) }.buttonStyle(PillButtonStyle(.neutral))
        }
        .accessibilityElement(children: .combine)
    }

    /// A Claude session needs the user, failed or finished: its chat card when the request is
    /// known (CompanionChatCard), else one row with Show.
    @ViewBuilder
    private func noticeCard(_ row: CompanionSessionRow) -> some View {
        if let request = row.request {
            CompanionChatCard(model: model, row: row, request: request)
        } else {
            sessionRow(row)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glass(cornerRadius: 14)
                .onHover { model.isHovering = $0 }
        }
    }

    /// Squares like the creature's bubbles (these rows only show beside the companion).
    private func sessionIcon(_ kind: CompanionSessionRow.Kind) -> some View {
        let (symbol, color): (String, Color) = switch kind {
        case .waiting: ("exclamationmark.square.fill", .orange)
        case .error: ("xmark.square.fill", PillStyle.captureRed)
        case .done: ("checkmark.square.fill", .green)
        }
        return Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: 15))
            .foregroundStyle(color)
            .frame(width: 18)
            .accessibilityHidden(true)
    }

    /// Quick dictation: only a scrolling waveform, no words (user decision 2026-10-04, like Wispr
    /// Flow). A running recording keeps a still red dot on the left so it never looks stopped.
    /// There is no success icon: the capsule shrinking back into the idle bar is the signal.
    /// Only a clipboard fallback says so in words, because then the text is not where expected.
    /// Until the microphone delivers sound the bars lie flat and dimmed with a sweep running
    /// across them (connecting, not silence); words spoken then are lost, so the user learns to
    /// speak once it lights up. A microphone still silent after 3 s is the one case in words.
    private func dictationCapsule(_ dictation: MeetingPillModel.Dictation) -> some View {
        HStack(spacing: 10) {
            if model.recordingStartedAt != nil {
                // Still and dimmed: the meeting keeps recording, but this capsule is dictation.
                RecordingDot(still: true)
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 1, height: 14)
                    .accessibilityHidden(true)
            }
            switch dictation {
            case .listening:
                DictationWave(levels: model.dictationLevels, live: model.dictationMicLive)
                micStalledNote
            case .inserting:
                // The bars run flat while the text is pasted, then the capsule shrinks away.
                DictationWave(levels: model.dictationLevels)
                    .opacity(0.5)
            case .done(let copied):
                if copied {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PillStyle.secondaryText)
                        .accessibilityHidden(true)
                    Text("Copied to clipboard")
                        .font(.system(size: 12))
                        .foregroundStyle(PillStyle.secondaryText)
                } else {
                    DictationWave(levels: model.dictationLevels)
                        .opacity(0.5)
                }
            case .claudeListening:
                ClaudeMark(working: false)
                if model.assistantHasSelection {
                    // The selected text goes along as context.
                    Image(systemName: "text.quote")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PillStyle.secondaryText)
                        .help("Your selected text goes to Claude too")
                        .accessibilityLabel("With selected text")
                }
                DictationWave(levels: model.dictationLevels, live: model.dictationMicLive)
                micStalledNote
                Button("Open Chat", action: model.openClaudeChat)
                    .buttonStyle(PillButtonStyle(.neutral))
                    .help("Continue in a Claude chat with what you said so far")
                Button(action: model.cancelClaudeTask) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(PillButtonStyle(.neutral))
                .help("Cancel")
                .accessibilityLabel("Cancel Claude task")
            case .claudeWorking:
                ClaudeMark(working: true)
                Text("Claude is on it\u{2026}")
                    .font(.system(size: 12))
                    .foregroundStyle(PillStyle.secondaryText)
            case .claudeCopied:
                ClaudeMark(working: false)
                Text("Copied \u{00B7} \u{2318}V to paste")
                    .font(.system(size: 12, weight: .medium))
            case .claudeFailed(let message):
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(PillStyle.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: 320, alignment: .leading)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, dictation == .claudeListening ? 4 : 12)
        .frame(height: 32)
        .glass(cornerRadius: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dictationAccessibilityLabel(dictation))
    }

    @ViewBuilder
    private var micStalledNote: some View {
        if model.dictationMicStalled && !model.dictationMicLive {
            Text("Microphone not ready")
                .font(.system(size: 12))
                .foregroundStyle(PillStyle.secondaryText)
                .lineLimit(1)
        }
    }

    private func dictationAccessibilityLabel(_ dictation: MeetingPillModel.Dictation) -> String {
        switch dictation {
        case .listening, .claudeListening:
            guard !model.dictationMicLive else { return Self.dictationLabel(dictation) }
            return model.dictationMicStalled ? "Microphone not ready" : "Microphone starting"
        default:
            return Self.dictationLabel(dictation)
        }
    }

    private func detectedCard(_ meeting: PillMeeting) -> some View {
        HStack(spacing: 10) {
            appIcon(meeting.appBundleID)
            VStack(alignment: .leading, spacing: 2) {
                Text(PillMeeting.displayTitle(meeting.title))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(meeting.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(PillStyle.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: PillStyle.titleWidth, alignment: .leading)
            Spacer(minLength: 16)
            HStack(spacing: 6) {
                Button("Not Now", action: model.ignore).buttonStyle(PillButtonStyle(.neutral))
                Button("Record") { model.record(meeting) }.buttonStyle(PillButtonStyle(.capture))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glass(cornerRadius: 16)
        .onHover { model.isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting detected: \(meeting.title)")
    }

    private func ring(_ meeting: PillMeeting) -> some View {
        Button {
            model.record(meeting)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "record.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PillStyle.secondaryText)
                if model.dotExpanded {
                    Text("Record \(PillMeeting.displayTitle(meeting.title))")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .frame(maxWidth: 200)
                        .transition(.opacity)
                }
            }
            .frame(height: 28)
            .padding(.horizontal, model.dotExpanded ? 10 : 6.5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glass(cornerRadius: 14)
        .onHover { hovering in model.hoverDot(hovering) }
        .contextMenu {
            Button("Record") { model.record(meeting) }
            Button("Not Now", action: model.ignore)
        }
        .accessibilityLabel("Record \(meeting.title)")
        .accessibilityHint("Meeting in progress, not recording")
    }

    private func consentCard(_ meeting: PillMeeting) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 17))
                .foregroundStyle(PillStyle.secondaryText)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tell everyone before you record")
                    .font(.system(size: 13, weight: .semibold))
                Text("In many places recording a call requires everyone's consent. You'll only see this once.")
                    .font(.system(size: 11))
                    .foregroundStyle(PillStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 250, alignment: .leading)
            Spacer(minLength: 16)
            HStack(spacing: 6) {
                Button("Not Now", action: model.ignore).buttonStyle(PillButtonStyle(.neutral))
                Button("Record") { model.confirmConsent(meeting) }.buttonStyle(PillButtonStyle(.capture))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glass(cornerRadius: 16)
        .onHover { model.isHovering = $0 }
    }

    private var recordingCapsule: some View {
        HStack(spacing: 10) {
            RecordingDot()
            LevelBars(level: model.level)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(Self.format(model.elapsed))
                    .font(.system(size: 12, weight: .medium, design: model.companionMode ? .monospaced : .default).monospacedDigit())
            }
            // Quick recordings stop with the dictation key; the controls replace the hint on hover.
            if let hint = model.recordingStopHint, !model.showsRecordingControls {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(PillStyle.secondaryText)
                    .accessibilityHidden(true)
            }
            if model.showsRecordingControls, model.companionMode, model.showsWheelHint {
                Text("Scroll over me to pick the project")
                    .font(.system(size: 11))
                    .foregroundStyle(PillStyle.secondaryText)
            }
            if model.showsRecordingControls {
                Button(action: model.openApp) {
                    Image(systemName: "arrow.up.forward.app")
                        .frame(minWidth: 14)
                }
                .buttonStyle(PillButtonStyle(.neutral))
                .accessibilityLabel("Open MinuteMind")
                Button(action: model.stop) {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill").font(.system(size: 9))
                        Text("Stop")
                    }
                }
                .buttonStyle(PillButtonStyle(.capture))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .glass(cornerRadius: 16)
        .onHover { model.hoverRecording($0) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording, \(Self.spoken(model.elapsed))\(model.recordingStopHint.map { ", press \($0)" } ?? "")")
        .accessibilityAction(named: "Stop Recording", model.stop)
        .accessibilityAction(named: "Open MinuteMind", model.openApp)
    }

    private func confirmStopCard(_ signal: MeetingPillModel.EndSignal) -> some View {
        HStack(spacing: 10) {
            RecordingDot()
            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting over?")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(Self.endSignalText(signal)) \u{00B7} still recording")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(PillStyle.secondaryText)
            }
            Spacer(minLength: 16)
            HStack(spacing: 6) {
                Button("Keep Recording", action: model.keepRecording).buttonStyle(PillButtonStyle(.neutral))
                Button(action: model.stop) {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill").font(.system(size: 9))
                        Text("Stop")
                    }
                }
                .buttonStyle(PillButtonStyle(.capture))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glass(cornerRadius: 16)
        .onHover { model.isHovering = $0 }
    }

    /// After a recording stops. Without a project it asks "Which project?": the recently used
    /// projects are one click each, Other lists every project and General, Later leaves it in the
    /// Inbox (user decision 2026-10-27: the user picks the project right after recording, then
    /// everything else happens on its own). With a project it says where it went, with Change.
    /// With automatic processing off: Later and Process Now.
    /// In a Shared Project it asks "Share with the Acme team?" with Publish and Keep private
    /// underneath (plus Change when it came filed already); see SharedPublishCard.swift.
    private func savedCard(sessionID: UUID, title: String, minutes: Int, next: MeetingPillModel.SavedNext) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: model.companionMode ? "checkmark.square.fill" : "checkmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 16))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(PillMeeting.displayTitle(title))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(0)
                        Text("saved").layoutPriority(1)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    Text("\(minutes) min \u{00B7} \(next.hint)")
                        .font(.system(size: 11))
                        .foregroundStyle(PillStyle.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Filed already: the question gets its own line under "Filed to X".
                    if case .publish(let project, true, _, _) = next {
                        Text(MeetingPillModel.SavedNext.publishQuestion(project))
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: PillStyle.titleWidth + 30, alignment: .leading)
                Spacer(minLength: 16)
                HStack(spacing: 6) {
                    switch next {
                    case .chooseProject:
                        Button("Later") { model.later(sessionID) }
                            .buttonStyle(PillButtonStyle(.neutral))
                            .help("Choose the project later in the Inbox")
                    case .filed(let project, _):
                        wheelButton("Change", sessionID: sessionID)
                        .accessibilityLabel("Change project")
                        .accessibilityValue(project)
                        Button("OK", action: model.dismissSaved).buttonStyle(PillButtonStyle(.neutral))
                    case .manual:
                        Button("Later") { model.later(sessionID) }.buttonStyle(PillButtonStyle(.neutral))
                        Button("Process Now") { model.process(sessionID) }.buttonStyle(PillButtonStyle(.constructive))
                    case .publish:
                        // Its buttons sit in the row below, under the question.
                        EmptyView()
                    }
                }
            }
            if case .publish(let project, let alreadyFiled, _, _) = next {
                HStack(spacing: 6) {
                    Button("Publish") { model.answerPublication(sessionID, .published) }
                        .buttonStyle(PillButtonStyle(.constructive))
                        .help("Share this recording with the \(project) team")
                        .accessibilityLabel("Publish to the \(project) team")
                    Button("Keep private") { model.answerPublication(sessionID, .keptPrivate) }
                        .buttonStyle(PillButtonStyle(.neutral))
                        .help("Only you see this recording")
                    if alreadyFiled {
                        wheelButton("Change", sessionID: sessionID)
                            .accessibilityLabel("Change project")
                            .accessibilityValue(project)
                    }
                }
            }
            if case .chooseProject(let quick, let all, _) = next {
                HStack(spacing: 6) {
                    ForEach(quick) { item in
                        Button {
                            model.chooseProject(sessionID, item)
                        } label: {
                            HStack(spacing: 6) {
                                projectDot(item.colorHex)
                                Text(item.name).lineLimit(1).truncationMode(.tail).frame(maxWidth: 96, alignment: .leading)
                            }
                        }
                        .buttonStyle(PillButtonStyle(.neutral))
                        .help(item.name)
                        .accessibilityLabel("File to \(item.name)")
                    }
                    if all.count > quick.count {
                        wheelButton(quick.isEmpty ? "Choose Project" : "Other", sessionID: sessionID)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { CountdownLine(progress: model.countdownProgress) }
        .glass(cornerRadius: 16)
        .onHover { model.isHovering = $0 }
        .accessibilityElement(children: .contain)
    }

    /// A project's colour mark: square beside the companion, round otherwise.
    private func projectDot(_ colorHex: String?) -> some View {
        let color = colorHex.map { Color(hex: $0) } ?? Color.primary.opacity(0.25)
        return Group {
            if model.companionMode { Rectangle().fill(color) } else { Circle().fill(color) }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }

    /// Opens the project wheel (the same list as scrolling over the companion) for this recording:
    /// pixel-styled beside the companion, scrollable, rows clickable, Later and Escape included.
    private func wheelButton(_ label: String, sessionID: UUID) -> some View {
        Button {
            model.openProjectWheel(sessionID)
        } label: {
            HStack(spacing: 4) {
                Text(label)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).accessibilityHidden(true)
            }
        }
        .buttonStyle(PillButtonStyle(.neutral))
        .accessibilityHint("Opens the list of projects")
    }

    // MARK: - Pieces

    @ViewBuilder
    private func appIcon(_ bundleID: String?) -> some View {
        Group {
            if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
            } else {
                Image(systemName: "calendar")
                    .font(.system(size: 18))
                    .foregroundStyle(PillStyle.secondaryText)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    private static func dictationLabel(_ dictation: MeetingPillModel.Dictation) -> String {
        switch dictation {
        case .listening: return "Dictating"
        case .inserting: return "Inserting dictated text"
        case .done(let copied): return copied ? "Dictated text copied to the clipboard" : "Dictated text inserted"
        case .claudeListening: return "Claude is listening. Tap fn to send."
        case .claudeWorking: return "Claude is working"
        case .claudeCopied: return "Claude's answer copied to the clipboard"
        case .claudeFailed(let message): return "Claude task failed: \(message)"
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    private static func spoken(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let minutes = total / 60, seconds = total % 60
        return "\(minutes) minutes \(seconds) seconds"
    }

    private static func endSignalText(_ signal: MeetingPillModel.EndSignal) -> String {
        switch signal {
        case .silence(let interval): return "Silent for \(minutes(interval))"
        case .callEnded(let appName): return "\(appName) call ended"
        }
    }

    private static func minutes(_ interval: TimeInterval) -> String {
        guard interval >= 60 else { return "\(Int(interval)) s" }
        return "\(Int(interval / 60)) min"
    }
}

// MARK: - Components

/// One copied text or image: the row copies it again (and says so before the card closes); the trailing
/// slot shows the age at rest and Insert on hover, in the same space so the row never reflows.
private struct ClipboardRow: View {
    static let height: CGFloat = 26

    let item: ClipboardHistory.Item
    let pixel: Bool
    let copy: () -> Void
    let insert: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                copied = true
                copy()
            } label: {
                HStack(spacing: 6) {
                    if case .image(let image) = item.content {
                        Image(nsImage: image.thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 32, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: pixel ? 0 : 3))
                            .overlay(RoundedRectangle(cornerRadius: pixel ? 0 : 3)
                                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                            .accessibilityHidden(true)
                    }
                    Text(item.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy to the clipboard")
            ZStack(alignment: .trailing) {
                if copied {
                    Label("Copied", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                } else if hovering {
                    Button("Insert", action: insert)
                        .buttonStyle(PillButtonStyle(.neutral))
                        .help("Paste where you are typing")
                } else {
                    Text(item.copiedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(.system(size: 11))
                        .foregroundStyle(PillStyle.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(width: 64, alignment: .trailing)
            .animation(.easeInOut(duration: 0.12), value: hovering)
        }
        .padding(.trailing, 2)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: pixel ? 0 : 6).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        .accessibilityHint("Copies it. Insert pastes it where you are typing.")
        .accessibilityAction(named: "Copy", copy)
        .accessibilityAction(named: "Insert", insert)
    }
}

private struct RecordingDot: View {
    /// No pulse, dimmed: the recording continues behind another state (dictation).
    var still = false
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pillPixelStyle) private var pixel

    var body: some View {
        if pixel {
            PixelRecordingDot(still: still)
        } else {
            roundDot
        }
    }

    private var roundDot: some View {
        // Solid core, pulsing halo: the dot never fades to pink.
        ZStack {
            if !still {
                Circle()
                    .fill(PillStyle.captureRed.opacity(0.35))
                    .frame(width: 8, height: 8)
                    .scaleEffect(dim && !reduceMotion ? 1.9 : 1)
                    .opacity(dim && !reduceMotion ? 0 : 0.8)
                    .animation(reduceMotion ? nil : .easeOut(duration: 1.6).repeatForever(autoreverses: false), value: dim)
            }
            Circle()
                .fill(PillStyle.captureRed)
                .frame(width: 8, height: 8)
                .opacity(still ? 0.6 : 1)
        }
        .frame(width: 14, height: 14)
        .onAppear { dim = true }
        .accessibilityHidden(true)
    }
}

/// Four bars following the audio level; dimmed after two seconds of silence.
private struct LevelBars: View {
    let level: Float
    @Environment(\.pillPixelStyle) private var pixel
    @State private var silentSince: Date? = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let weights: [CGFloat] = [0.6, 1.0, 0.85, 0.5]
    /// Resting heights, so silence reads as a quiet meter rather than "••••".
    private let resting: [CGFloat] = [5, 8, 6, 4]

    var body: some View {
        if pixel {
            PixelLevelBars(level: level)
        } else {
            roundedBars
        }
    }

    @ViewBuilder
    private var roundedBars: some View {
        let normalized = CGFloat(min(1, sqrt(max(0, level)) * 3))
        let isSilent = normalized < 0.08
        let dimmed = isSilent && (silentSince.map { Date().timeIntervalSince($0) > 2 } ?? false)
        HStack(alignment: .center, spacing: 2) {
            ForEach(weights.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: 3, height: min(14, resting[index] + 9 * normalized * weights[index]))
            }
        }
        .frame(height: 14)
        .opacity(dimmed ? 0.35 : 1)
        .animation(reduceMotion ? nil : .interpolatingSpring(stiffness: 300, damping: 20), value: level)
        .onChange(of: isSilent) { _, silent in silentSince = silent ? Date() : nil }
        .accessibilityHidden(true)
    }
}

/// Marks a Claude task in the pill, in the theme accent so it never reads as dictation or
/// recording. Pulses while Claude works.
private struct ClaudeMark: View {
    let working: Bool

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(PillStyle.claude)
            .symbolEffect(.pulse, isActive: working)
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
    }
}

/// Scrolling waveform for dictation: one bar per recent level sample, newest on the right.
private struct DictationWave: View {
    let levels: [Float]
    /// False while the microphone starts: flat bars at 0.22 with a highlight sweeping across.
    var live = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pillPixelStyle) private var pixel

    var body: some View {
        if pixel {
            PixelDictationWave(levels: levels, live: live)
        } else {
            smoothWave
        }
    }

    private var smoothWave: some View {
        TimelineView(.animation(paused: live || reduceMotion)) { context in
            HStack(alignment: .center, spacing: 2) {
                ForEach(levels.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(live ? 0.75 : waitingOpacity(bar: index, at: context.date)))
                        .frame(width: 2, height: live ? max(3, 16 * CGFloat(min(1, sqrt(max(0, levels[index])) * 3))) : 3)
                }
            }
        }
        .frame(height: 16)
        .animation(reduceMotion ? nil : .linear(duration: 0.06), value: levels)
        .animation(.easeOut(duration: 0.08), value: live)
        .accessibilityHidden(true)
    }

    /// A highlight about five bars wide passes left to right to 0.5, once every 0.9 s.
    private func waitingOpacity(bar: Int, at date: Date) -> Double {
        guard !reduceMotion else { return 0.22 }
        let pass = 0.9
        let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: pass) / pass
        let center = -2.5 + progress * Double(levels.count + 5)
        let lift = max(0, 1 - abs(Double(bar) - center) / 2.5)
        return 0.22 + 0.28 * lift
    }
}

/// A 2 pt line along the bottom edge that drains as the countdown runs out.
private struct CountdownLine: View {
    let progress: Double
    @Environment(\.pillPixelStyle) private var pixel

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(pixel ? DesignSystem.Colors.accent : Color.primary.opacity(0.25))
                .frame(width: proxy.size.width * max(0, min(1, progress)), height: 2)
                .animation(.linear(duration: 1), value: progress)
        }
        .frame(height: 2)
        // Inside the pixel border, where a line along the edge would vanish into it.
        .padding(.horizontal, pixel ? 6 : 0)
        .padding(.bottom, pixel ? 4 : 0)
        .accessibilityHidden(true)
    }
}

struct PillButtonStyle: ButtonStyle {
    enum Kind { case neutral, capture, constructive }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }

    func makeBody(configuration: Configuration) -> some View {
        PillButtonSwitch(configuration: configuration, kind: kind)
    }

    /// The pixel button beside the companion, the capsule otherwise.
    private struct PillButtonSwitch: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @Environment(\.pillPixelStyle) private var pixel

        var body: some View {
            if pixel {
                PixelButtonBody(configuration: configuration, kind: kind)
            } else {
                PillButtonBody(configuration: configuration, kind: kind)
            }
        }
    }

    private struct PillButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(Capsule().fill(fill))
                .foregroundStyle(kind == .neutral ? Color.primary : Color.white)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            switch kind {
            case .neutral:
                return Color.primary.opacity(configuration.isPressed ? 0.18 : hovering ? 0.12 : 0.08)
            case .capture:
                return PillStyle.captureRed.opacity(configuration.isPressed ? 0.8 : hovering ? 0.92 : 1)
            case .constructive:
                return Color.accentColor.opacity(configuration.isPressed ? 0.8 : hovering ? 0.92 : 1)
            }
        }
    }
}

private struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct Glass: ViewModifier {
    let cornerRadius: CGFloat
    /// Idle bar: a lighter shadow so a permanent element stays out of the way.
    var quiet = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.pillPixelStyle) private var pixel

    func body(content: Content) -> some View {
        if pixel {
            content
                .clipShape(PixelPanelShape())
                .modifier(PixelPanelBackground())
        } else {
            glass(content)
        }
    }

    @ViewBuilder
    private func glass(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let increased = contrast == .increased
        content
            .background {
                ZStack {
                    GlassBackground()
                    // Neutral wash so the wallpaper does not tint the frost.
                    colorScheme == .dark
                        ? Color.black.opacity(increased ? 0.6 : 0.20)
                        : Color.white.opacity(increased ? 0.85 : 0.55)
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.primary.opacity(increased ? 0.35 : 0.08), lineWidth: increased ? 1 : 0.5)
            }
            .overlay {
                if colorScheme == .light && !increased {
                    shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.6), .clear], startPoint: .top, endPoint: .center),
                        lineWidth: 0.5)
                }
            }
            .shadow(color: .black.opacity(quiet ? 0.12 : 0.10), radius: 1, y: 0.5)
            .shadow(color: .black.opacity(quiet ? 0.10 : 0.16), radius: quiet ? 3 : 14, y: quiet ? 1 : 6)
    }
}

extension View {
    /// The pill's card background (frosted, or the pixel finish beside the companion).
    func glass(cornerRadius: CGFloat, quiet: Bool = false) -> some View {
        modifier(Glass(cornerRadius: cornerRadius, quiet: quiet))
    }
}
