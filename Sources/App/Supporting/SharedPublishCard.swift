// Purpose: The rules of the saved card's publish question for meetings and quick recordings in a
//          Shared Project: when the card asks "Share with the Acme team?", what a project pick
//          turns it into, what follows Publish / Keep private, and what closing it unanswered
//          means. Pure state, no timing or UI, so the rules are tested on their own.
// Dependencies: Sources/App/Supporting/MeetingPillController.swift (MeetingPillModel.SavedNext),
//               Sources/App/Models/SharedProject.swift (MeetingPublication)
// RBAC: None. Publishing only records the owner's choice; the sync does the rest.
// Used by: Sources/App/Supporting/MeetingPillController.swift (recordingStopped, projectChosen,
//          publicationAnswered, finishSaved), Tests/SharedPublishCardTests.swift
// Notes: - No answer means private: nothing leaves the Mac until the user says Publish. The 30 s
//          timeout, Escape, Later and the process hotkey all close the question as Keep private.
//        - Only a Shared Project asks. A Private project or General keeps the "Filed to X" card
//          as it is; picking another Shared Project with Change asks again (the question belongs
//          to the project, so an earlier pick's question never carries over).
//        - A question picked on the card has no Change: the user just chose that project.
//        - With automatic processing off the answer leads to the usual Process Now card, so the
//          question adds a step instead of replacing the flow.

import Foundation

extension MeetingPillModel.SavedNext {
    /// "Share with the Acme team?"
    static func publishQuestion(_ project: String) -> String {
        "Share with the \(project) team?"
    }

    /// Whether picking a project starts processing on its own (automatic processing on).
    var processes: Bool {
        switch self {
        case .chooseProject(_, _, let processes), .publish(_, _, _, let processes): return processes
        case .filed: return true
        case .manual: return false
        }
    }

    var asksToPublish: Bool {
        if case .publish = self { return true }
        return false
    }

    /// A question (which project, publish or not) waits 30 s; a note 15 s.
    var waitsForAnswer: Bool { asksForProject || asksToPublish }

    /// Right after the recording stopped: filed to a Shared Project (by name), the card asks
    /// whether to publish. Without a project it still asks which one first.
    func askingToPublish(sharedProject: String?) -> Self {
        guard let sharedProject else { return self }
        switch self {
        case .filed(_, let all):
            return .publish(project: sharedProject, alreadyFiled: true, all: all, processes: true)
        case .manual:
            return .publish(project: sharedProject, alreadyFiled: true, all: [], processes: false)
        case .chooseProject, .publish:
            return self
        }
    }

    /// A project was picked on the card (buttons, Other, Change or the project wheel).
    func picking(_ project: String, shared: Bool) -> Self {
        if shared {
            return .publish(project: project, alreadyFiled: false, all: allChoices, processes: processes)
        }
        return processes ? .filed(project: project, all: allChoices) : .manual
    }

    /// After Publish or Keep private: nil closes the card (like OK); with automatic processing
    /// off the card offers Process Now.
    var afterPublishAnswer: Self? {
        guard asksToPublish else { return nil }
        return processes ? nil : .manual
    }

    /// What closing the card without an answer records: Keep private while it asks to publish,
    /// nothing otherwise.
    var unansweredPublication: MeetingPublication? {
        asksToPublish ? .keptPrivate : nil
    }
}
