// Purpose: Edits a task title in place inside task rows and board cards. Enter or a click
//          elsewhere saves, Tab and Shift-Tab save and move on to the neighbouring task, Esc
//          discards.
// Dependencies: AppKit (NSTextField), SwiftUI, AppViewModel.updateTaskTitle
// RBAC: None.
// Dependents: Sources/App/Views/AllTasksView.swift (AllTasksRowView),
//             Sources/App/Views/ProjectDetailView.swift (TaskRowView),
//             Sources/App/Views/WorkboardCardView.swift, Sources/App/Views/WorkboardView.swift
// Notes: An AppKit field instead of a SwiftUI TextField: a SwiftUI field hands Tab to the focus
//        system before the view sees it, so "save and go to the next task" could not be told
//        apart from a click elsewhere.
//        A click on plain SwiftUI content does not take first responder, so the field would stay
//        in edit mode. A local mouse-down monitor ends the edit on any click outside the field;
//        the click still reaches its target.
//        The end of an edit is reported asynchronously: it can fire while SwiftUI tears the field
//        down (another task starts editing), and state must not change during a view update.

import AppKit
import SwiftUI

/// How an inline title edit ended.
enum InlineTitleEditEnd: Equatable {
    case save
    case saveAndNext
    case saveAndPrevious
    case cancel
}

/// Rules for inline title edits, shared by every task list and the board.
enum InlineTaskTitleEditing {
    /// The task to edit next, nil when editing stops. Tab past the last task stops editing.
    static func nextTaskID(after taskID: UUID, end: InlineTitleEditEnd, order: [UUID]) -> UUID? {
        guard let index = order.firstIndex(of: taskID) else { return nil }
        switch end {
        case .save, .cancel:
            return nil
        case .saveAndNext:
            return order.indices.contains(index + 1) ? order[index + 1] : nil
        case .saveAndPrevious:
            return index > 0 ? order[index - 1] : nil
        }
    }

    /// The title to store, nil when nothing changes: cancelled, unchanged or left empty.
    static func titleToSave(draft: String, current: String, end: InlineTitleEditEnd) -> String? {
        guard end != .cancel else { return nil }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != current else { return nil }
        return trimmed
    }

    /// Saves the draft and hands editing on to the next task. Leaves `editingTaskID` alone when
    /// another task already took over (a double-click on another row ends this edit).
    @MainActor
    static func finish(
        _ task: ProjectTask, draft: String, end: InlineTitleEditEnd, order: [UUID],
        editingTaskID: Binding<UUID?>, viewModel: AppViewModel
    ) {
        if let title = titleToSave(draft: draft, current: task.title, end: end) {
            viewModel.updateTaskTitle(task, title: title)
        }
        guard editingTaskID.wrappedValue == task.id else { return }
        editingTaskID.wrappedValue = nextTaskID(after: task.id, end: end, order: order)
    }
}

/// A borderless single-line field that takes focus as soon as it appears.
struct InlineTaskTitleField: NSViewRepresentable {
    let title: String
    let font: NSFont
    let onEnd: (String, InlineTitleEditEnd) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEnd: onEnd)
    }

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField(string: title)
        field.font = font
        field.isBordered = false
        field.drawsBackground = false
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.onWindow = { [weak coordinator = context.coordinator] in
            coordinator?.startWatchingClicks()
        }
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        context.coordinator.onEnd = onEnd
    }

    static func dismantleNSView(_ field: FocusingTextField, coordinator: Coordinator) {
        coordinator.end(.save)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onEnd: (String, InlineTitleEditEnd) -> Void
        weak var field: NSTextField?
        private var ended = false
        private var clickMonitor: Any?

        init(onEnd: @escaping (String, InlineTitleEditEnd) -> Void) {
            self.onEnd = onEnd
        }

        func end(_ how: InlineTitleEditEnd) {
            guard !ended else { return }
            ended = true
            stopWatchingClicks()
            let draft = field?.currentEditor()?.string ?? field?.stringValue ?? ""
            let onEnd = self.onEnd
            DispatchQueue.main.async { onEnd(draft, how) }
        }

        func startWatchingClicks() {
            guard clickMonitor == nil, !ended else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let field = self.field, event.window === field.window else { return }
                    let point = field.convert(event.locationInWindow, from: nil)
                    if !field.bounds.contains(point) { self.end(.save) }
                }
                return event
            }
        }

        private func stopWatchingClicks() {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                end(.save)
            case #selector(NSResponder.insertTab(_:)):
                end(.saveAndNext)
            case #selector(NSResponder.insertBacktab(_:)):
                end(.saveAndPrevious)
            case #selector(NSResponder.cancelOperation(_:)):
                end(.cancel)
            default:
                return false
            }
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            end(.save)
        }
    }

    /// Becomes first responder once it is in a window and puts the cursor at the end.
    final class FocusingTextField: NSTextField {
        var onWindow: (() -> Void)?
        private var didFocus = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !didFocus else { return }
            didFocus = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
                let end = (self.currentEditor()?.string as NSString?)?.length ?? 0
                self.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
                self.onWindow?()
            }
        }
    }
}
