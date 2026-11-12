// Purpose: CompanionChatCard, the small chat beside the desktop companion for one Claude session:
//          what the session asks or answered, and the ways to answer it right there (Allow or
//          Deny a tool, pick an option, type a reply) or to open the session.
// Dependencies: Sources/App/Supporting/ClaudeSessionRequest.swift (requests and answers),
//               Sources/App/Supporting/MeetingPillController.swift (MeetingPillModel, CompanionSessionRow),
//               Sources/App/Views/MeetingPillView.swift (PillButtonStyle, PillStyle, glass),
//               Sources/App/Views/CompanionView.swift (MascotCanvas for the speaker's face),
//               Sources/App/Views/CompanionChatMarkdown.swift (Theme.companionChat)
// Used by: Sources/App/Views/MeetingPillView.swift (the notice beside the companion)
// Notes: Step 2 of the project creatures (user request: "a little chat window in the pixel style
//        in which I can reply or answer the request, or decide to go to it"). Decisions:
//        - The card speaks as the creature: its face (the project's creature, or the home
//          companion) and the project in the header, so it is clear who asks.
//        - The primary answer per request: Allow for a tool (Deny next to it, a typed reply
//          declines and says what to do instead), the options of a single question, a reply to
//          a finished turn or an error. Plans and questions the card cannot answer show what
//          they are about and point to Open.
//        - Open is always there: the keys may not fit a later Claude Code (ClaudeSessionRequest).
//        - The reply field never takes the keyboard by itself (MeetingPillController); Return
//          sends, the card stays while a reply is being typed.
//        - Long text scrolls inside a fixed height, so the card never grows over the screen.
//        - Claude's text (question, plan, last message, error, waiting note) is Markdown and is
//          rendered (Theme.companionChat); a permission's detail is a command and stays plain
//          monospaced text.
//        - Safety (design review): Allow only arms `armDelay` after the card or its request
//          appears (it can open under a moving pointer), is never on Return, and turns neutral
//          when the command is unknown; the store types nothing when the request is no longer
//          the one shown. One blue button per card; a typed reply to a permission says "Deny and
//          Send". Esc closes the card and never declines.
//        - Sizes (`Metrics`) sit above the other cards beside the companion: this card is read,
//          not glanced at, so its text is 14 pt and the card 380 pt wide. Buttons keep the
//          shared PillButtonStyle size.

import MarkdownUI
import SwiftUI

struct CompanionChatCard: View {
    @Bindable var model: MeetingPillModel
    let row: CompanionSessionRow
    let request: ClaudeSessionRequest
    /// Allow is clickable only once this is true.
    @State private var armed = false
    private static let armDelay: Duration = .milliseconds(600)

    private enum Metrics {
        static let width: CGFloat = 380
        static let headline: CGFloat = 15
        static let body: CGFloat = 14
        static let secondary: CGFloat = 12
        static let code: CGFloat = 12
        static let permissionHeight: CGFloat = 80
        static let planHeight: CGFloat = 180
        static let messageHeight: CGFloat = 220
        static let failedHeight: CGFloat = 90
        static let waitingHeight: CGFloat = 70
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            if request.takesReply { replyField }
            footer
        }
        .padding(12)
        .frame(width: Metrics.width, alignment: .leading)
        .glass(cornerRadius: 14)
        .onHover { model.isHovering = $0 }
        .onExitCommand(perform: model.closeNotice)
        .task(id: request) {
            armed = false
            try? await Task.sleep(for: Self.armDelay)
            armed = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(headline), \(row.project), \(row.session)")
    }

    private var header: some View {
        HStack(spacing: 8) {
            MascotCanvas(
                frame: AssistantMascotPose.frame(.init(
                    mood: row.kind == .done ? .idle : .waiting, time: 0.05, look: nil,
                    avatar: row.avatar ?? CompanionAppearance.shared.avatar, animated: false)),
                avatar: row.avatar, pixelSize: 2, bodyColor: row.avatarColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline).font(.system(size: Metrics.headline, weight: .semibold)).lineLimit(1)
                Text("\(row.project) \u{00B7} \(row.session)")
                    .font(.system(size: Metrics.secondary)).foregroundStyle(PillStyle.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: model.closeNotice) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(PillStyle.secondaryText)
            .help("Close")
            .accessibilityLabel("Close")
        }
    }

    private var headline: String {
        switch request {
        case .permission: "Claude asks for permission"
        case .question: "Claude has a question"
        case .plan: "Claude has a plan ready"
        case .finished: "Claude is done"
        case .failed: "Claude ran into an error"
        case .waiting: "Claude needs you"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch request {
        case .permission(let tool, let detail):
            VStack(alignment: .leading, spacing: 6) {
                Text("Wants to use \(tool)").font(.system(size: Metrics.body, weight: .medium))
                if detail.isEmpty {
                    Text("Open the session to see what it would do.")
                        .font(.system(size: Metrics.secondary)).foregroundStyle(PillStyle.secondaryText)
                } else {
                    scrolling(detail, monospaced: true, maxHeight: Metrics.permissionHeight)
                }
            }
        case .question(let text, let options):
            VStack(alignment: .leading, spacing: 6) {
                markdown(text)
                if options.isEmpty {
                    Text("Answer it in the session.").font(.system(size: Metrics.secondary)).foregroundStyle(PillStyle.secondaryText)
                } else {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        Button { model.answerSession(row, .option(index)) } label: {
                            HStack(spacing: 8) {
                                Text("\(index + 1)").monospacedDigit().foregroundStyle(PillStyle.secondaryText)
                                Text(option).lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: Metrics.body))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PillButtonStyle(.neutral))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Option \(index + 1) of \(options.count), \(option)")
                    }
                }
            }
        case .plan(let plan):
            VStack(alignment: .leading, spacing: 6) {
                if !plan.isEmpty { scrolling(plan, maxHeight: Metrics.planHeight) }
                Text("Review and approve it in the session.").font(.system(size: Metrics.secondary)).foregroundStyle(PillStyle.secondaryText)
            }
        case .finished(let message):
            if message.isEmpty {
                Text("Finished without a message.").font(.system(size: Metrics.body)).foregroundStyle(PillStyle.secondaryText)
            } else {
                scrolling(message, maxHeight: Metrics.messageHeight)
            }
        case .failed(let message):
            scrolling(message ?? "The turn ended with an error.", secondary: true, maxHeight: Metrics.failedHeight)
        case .waiting(let message):
            scrolling(message ?? "It waits for you in the session.", secondary: true, maxHeight: Metrics.waitingHeight)
        }
    }

    /// Text that scrolls inside `maxHeight`: Markdown, or with `monospaced` a command as it is.
    private func scrolling(
        _ text: String, monospaced: Bool = false, secondary: Bool = false, maxHeight: CGFloat
    ) -> some View {
        ScrollView {
            Group {
                if monospaced {
                    Text(text).font(.system(size: Metrics.code, design: .monospaced))
                } else {
                    markdown(text, secondary: secondary)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Claude's Markdown at the card's text size; `secondary` greys it like a note.
    @ViewBuilder
    private func markdown(_ text: String, secondary: Bool = false) -> some View {
        if secondary {
            Markdown(text)
                .markdownTheme(.companionChat(size: Metrics.body))
                .markdownTextStyle(\.text) {
                    FontSize(Metrics.body)
                    ForegroundColor(PillStyle.secondaryText)
                }
        } else {
            Markdown(text)
                .markdownTheme(.companionChat(size: Metrics.body))
        }
    }

    private var replyPrompt: String {
        if case .permission = request { return "Or tell Claude what to do instead" }
        return "Reply to Claude"
    }

    /// Return sends; Option+Return starts a new line.
    private var replyField: some View {
        TextField(replyPrompt, text: $model.sessionDraft, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: Metrics.body))
            .lineLimit(1...4)
            .onSubmit(sendReply)
    }

    private var isPermission: Bool {
        if case .permission = request { return true }
        return false
    }

    private var permissionLabel: String {
        if case .permission(let tool, let detail) = request { return detail.isEmpty ? tool : "\(tool): \(detail)" }
        return ""
    }

    private var draftIsEmpty: Bool {
        model.sessionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendReply() {
        guard !draftIsEmpty else { return }
        let text = model.sessionDraft
        model.answerSession(row, isPermission ? .denyWith(text) : .reply(text))
    }

    /// One row of actions, one blue button: Allow for a permission (Deny and Send once a reply
    /// is typed), else Send for a reply.
    private var footer: some View {
        HStack(spacing: 6) {
            Button("Open Session") { model.showSession(row.id) }
                .buttonStyle(PillButtonStyle(.neutral))
            Spacer(minLength: 0)
            if isPermission {
                if draftIsEmpty {
                    Button("Deny") { model.answerSession(row, .deny) }
                        .buttonStyle(PillButtonStyle(.neutral))
                        .accessibilityLabel("Deny \(permissionLabel)")
                    Button("Allow Once") { model.answerSession(row, .allow) }
                        .buttonStyle(PillButtonStyle(hasDetail ? .constructive : .neutral))
                        .disabled(!armed)
                        .accessibilityLabel("Allow \(permissionLabel) once")
                } else {
                    Button("Deny and Send", action: sendReply)
                        .buttonStyle(PillButtonStyle(.constructive))
                }
            } else if request.takesReply {
                Button("Send", action: sendReply)
                    .buttonStyle(PillButtonStyle(.constructive))
                    .disabled(draftIsEmpty)
            }
        }
    }

    private var hasDetail: Bool {
        if case .permission(_, let detail) = request { return !detail.isEmpty }
        return false
    }
}
