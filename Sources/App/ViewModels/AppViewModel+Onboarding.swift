// Purpose: Launch work that belongs to the first-run setup: the General workspace exists for
//          everyone from the first launch on, and the launch right after the setup's restart
//          opens on General.
// Dependencies: Sources/App/Services/ProjectRepositoryService.swift (ensureRepository, General),
//               Sources/App/Supporting/OnboardingFlow.swift (restart flag)
// Used by: Sources/App/Views/ContentView.swift (launch task),
//          Sources/App/Supporting/OnboardingFlow.swift (finish)
// Notes: General used to be created only when the first meeting was filed there, so a new user
//        had no General folder for Claude (General) or Jobs. ensureRepository is idempotent and
//        cheap once the repo exists. Skipped in test processes like the other launch-time work.

import Foundation

extension AppViewModel {
    /// Creates the General workspace repo when it is missing (git init, CLAUDE.md, first commit).
    func ensureGeneralWorkspace() {
        guard !Self.isTestProcess else { return }
        projectRepositories.ensureRepository(for: ProjectRepositoryService.generalProject)
    }

    /// Called once when the main window first appears.
    func runOnboardingLaunchWork() {
        ensureGeneralWorkspace()
        if OnboardingFlow.consumeSelectGeneral() {
            selectedProjectID = ProjectRepositoryService.generalProjectID
        }
    }
}
