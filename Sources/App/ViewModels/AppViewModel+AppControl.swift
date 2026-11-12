// Purpose: AppViewModel+AppControl, app actions Claude triggers over MCP: bring a place in the app
//          to the front (a Settings page, a sidebar destination, a project tab) and start or stop
//          a recording, with a plain-language result for Claude to pass on.
// Dependencies: Sources/App/ViewModels/AppViewModel.swift (navigation flags, requestedProjectTab,
//               requestedSettingsTab, openWindowAction, startRecording, stopRecording),
//               Sources/App/ViewModels/AppViewModel+Companion.swift (mainWindow),
//               Sources/App/Views/MeetingMinutesSettingsView.swift (Tab),
//               Sources/App/Views/ProjectDetailView.swift (ProjectTab)
// Used by: Sources/App/Services/MCP/MCPAppControlTools.swift
// Notes: Navigation sets the same flags the sidebar sets and reuses requestedProjectTab, which
//        ProjectDetailView and GeneralWorkspaceView already consume. Recording goes through
//        startRecording / stopRecording like the record button, so the pill, the companion and the
//        project rules (export folder) behave the same; the project picked for it becomes the
//        record picker's choice, as if the user had picked it there.

import AppKit
import Foundation

extension AppViewModel {
    enum AppDestination: Equatable {
        case settings(MeetingMinutesSettingsView.Tab)
        case allTranscripts, inbox, allTasks, calendar, clipboard
        /// A project (General included, `ProjectRepositoryService.generalProjectID`) and optionally a tab.
        case project(UUID, ProjectTab?)
    }

    enum AppControlError: Error, LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let message): message
            }
        }
    }

    /// Brings MinuteMind forward on the destination.
    func show(_ destination: AppDestination) throws {
        NSApp.activate(ignoringOtherApps: true)
        if case .settings(let tab) = destination {
            guard let openWindowAction else { throw AppControlError.failed("MinuteMind's main window has not opened yet.") }
            requestedSettingsTab = tab
            openWindowAction(id: "settings")
            return
        }
        isShowingAllTasks = false
        isShowingCalendar = false
        isShowingInbox = false
        isShowingClipboard = false
        switch destination {
        case .settings: break
        case .allTranscripts: selectedProjectID = nil
        case .inbox: isShowingInbox = true
        case .allTasks: isShowingAllTasks = true
        case .calendar: isShowingCalendar = true
        case .clipboard: isShowingClipboard = true
        case .project(let id, let tab):
            guard id == ProjectRepositoryService.generalProjectID || projects.contains(where: { $0.id == id }) else {
                throw AppControlError.failed("No project with id \(id.uuidString).")
            }
            selectedProjectID = id
            requestedProjectTab = tab
        }
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else if let openWindowAction {
            openWindowAction(id: "main")
        } else {
            throw AppControlError.failed("MinuteMind's main window has not opened yet.")
        }
    }

    /// Starts a recording like the record button. `projectID` (a project or General) becomes the
    /// record picker's choice first; nil keeps the picker as it is.
    func startRecordingFromClaude(projectID: UUID?, title: String?) async throws -> RecordingSession {
        guard !isRecording else { throw AppControlError.failed("A recording is already running.") }
        if let projectID {
            guard projectID == ProjectRepositoryService.generalProjectID || projects.contains(where: { $0.id == projectID }) else {
                throw AppControlError.failed("No project with id \(projectID.uuidString).")
            }
            pendingProjectID = projectID
        }
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            pendingSessionTitle = title
        }
        errorMessage = nil
        await startRecording()
        guard isRecording, let session = currentSession else {
            throw AppControlError.failed(errorMessage ?? "The recording did not start.")
        }
        return session
    }

    /// Stops the running recording like the Stop button; transcription follows by itself.
    func stopRecordingFromClaude() async throws -> RecordingSession {
        guard isRecording, let running = currentSession else { throw AppControlError.failed("No recording is running.") }
        await stopRecording()
        return sessions.first { $0.id == running.id } ?? running
    }
}
