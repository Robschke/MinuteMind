// Purpose: OnboardingFlow, the first-launch setup's state: which step shows, whether the setup is
//          due at all, the speech model downloads that run in the background while the tour
//          plays, and the restart that ends it.
// Dependencies: Sources/App/Supporting/OnboardingPermissions.swift (permission steps),
//               Sources/App/ViewModels/AppViewModel.swift (Parakeet install, diarization models,
//               automation settings, projects and sessions on disk),
//               Sources/App/Services/SpeakerDiarizationModelStore.swift (Nemotron download)
// Used by: Sources/App/Views/ContentView.swift (shows OnboardingView while active),
//          Sources/App/Views/OnboardingView.swift and its pages, Sources/App/MinuteMindApp.swift
//          (Help > Show Welcome Tour), Sources/App/ViewModels/AppViewModel+Onboarding.swift
// Notes: Shown on its own only for a new install: no projects, no recordings, no Parakeet model.
//        Everyone else is marked done the first time this build runs and can open it from the
//        Help menu. The current step is stored, so quitting halfway resumes there.
//        The downloads start on the models page and keep running through the tour; the finish
//        page waits for them before it offers the restart, so one restart settles everything
//        (screen recording and accessibility only take full effect in a new process, and the
//        Claude CLI lookup is cached per run).
//        Once Nemotron is installed the setup switches speaker diarization on with Nemotron 3.
//        A singleton, like ThemeStore, so AppViewModel needs no stored property for it.

import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class OnboardingFlow {
    static let shared = OnboardingFlow()

    enum Step: Hashable, Identifiable {
        case welcome
        case permission(OnboardingPermission)
        case claude
        case models
        case tour(OnboardingTourTopic)
        case finish

        var id: String {
            switch self {
            case .welcome: "welcome"
            case .permission(let permission): "permission.\(permission.rawValue)"
            case .claude: "claude"
            case .models: "models"
            case .tour(let topic): "tour.\(topic.rawValue)"
            case .finish: "finish"
            }
        }
    }

    enum DownloadState: Equatable {
        case notStarted
        case downloading
        case done
        case failed(String)
    }

    static let steps: [Step] = {
        var steps: [Step] = [.welcome]
        steps.append(contentsOf: OnboardingPermission.allCases.map { Step.permission($0) })
        steps.append(contentsOf: [.claude, .models])
        steps.append(contentsOf: OnboardingTourTopic.allCases.map { Step.tour($0) })
        steps.append(.finish)
        return steps
    }()

    private static let completedKey = "mm.onboardingCompleted"
    private static let stepKey = "mm.onboardingStep"
    private static let selectGeneralKey = "mm.onboardingSelectGeneral"

    private(set) var isPrepared = false
    private(set) var isActive = false
    /// Opened from the Help menu after the setup was done once: Finish may close without a restart.
    private(set) var isRerun = false
    private(set) var index = 0
    private(set) var downloads: DownloadState = .notStarted
    private var downloadTask: Task<Void, Never>?
    /// Claude Code and MCP state, shared by the Claude page and the finish page.
    let claude = OnboardingClaudeSetup()

    var step: Step { Self.steps[index] }
    var isFirst: Bool { index == 0 }
    var isLast: Bool { index == Self.steps.count - 1 }

    /// Each permission's state as its page last read it (polled while the page shows).
    var permissionStates: [OnboardingPermission: OnboardingPermissionState] = [:]

    /// The footer's forward button for the current step: "Not now" while the step's thing is
    /// still open, nil on the finish page, which has its own buttons.
    var continueLabel: String? {
        switch step {
        case .welcome: return "Get Started"
        case .permission(let permission):
            let state = permissionStates[permission]
            return state == .granted || state == .pendingRestart ? "Continue" : "Not now"
        case .claude: return claude.mcp == .added ? "Continue" : "Not now"
        case .models: return downloads == .notStarted ? "Not now" : "Continue"
        case .tour: return "Continue"
        case .finish: return nil
        }
    }

    // MARK: - Showing

    /// Decides once per launch whether the setup shows. A new install gets it; an existing one is
    /// marked done so it never appears by surprise.
    func prepare(for viewModel: AppViewModel) {
        guard !isPrepared else { return }
        isPrepared = true
        guard !AppViewModel.isTestProcess else { return }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.completedKey) == nil {
            let hasData = !viewModel.projects.isEmpty
                || viewModel.parakeetModelInstalled
                || Self.hasStoredSessions
            defaults.set(hasData, forKey: Self.completedKey)
        }
        guard !defaults.bool(forKey: Self.completedKey) else { return }
        if let saved = defaults.string(forKey: Self.stepKey),
           let position = Self.steps.firstIndex(where: { $0.id == saved }) {
            index = position
        }
        isActive = true
    }

    /// Whether sessions.json holds at least one recording. Read directly, because the sessions
    /// load asynchronously after the window appears.
    private static var hasStoredSessions: Bool {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MinuteMind/sessions.json"),
            let data = try? Data(contentsOf: url),
            let list = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return false }
        return !list.isEmpty
    }

    /// Help > Show Welcome Tour: the whole setup again from the start.
    func showAgain() {
        index = 0
        isRerun = UserDefaults.standard.bool(forKey: Self.completedKey)
        isActive = true
    }

    // MARK: - Moving

    func next() { go(to: index + 1) }
    func back() { go(to: index - 1) }

    /// The finish page's shortcuts back to a step that is still open.
    func jump(to target: Step) {
        if let position = Self.steps.firstIndex(of: target) { go(to: position) }
    }

    private func go(to position: Int) {
        guard Self.steps.indices.contains(position) else { return }
        index = position
        UserDefaults.standard.set(step.id, forKey: Self.stepKey)
    }

    // MARK: - Models

    var isParakeetReady: Bool = false
    var isNemotronReady: Bool = false

    func refreshModelState(_ viewModel: AppViewModel) {
        isParakeetReady = viewModel.parakeetModelInstalled
        isNemotronReady = viewModel.speakerDiarizationModels.isNemotronInstalled
        if isParakeetReady && isNemotronReady && downloads == .notStarted { downloads = .done }
    }

    /// Downloads Parakeet, then Nemotron (with the base diarization models it builds on), and
    /// switches diarization on with Nemotron. Keeps running while the user moves on.
    func startDownloads(_ viewModel: AppViewModel) {
        guard downloadTask == nil else { return }
        downloads = .downloading
        downloadTask = Task { [weak self] in
            guard let self else { return }
            var failures: [String] = []

            if !viewModel.parakeetModelInstalled {
                await viewModel.installParakeetModel()
                if !viewModel.parakeetModelInstalled {
                    // The install reports through the app-wide alert; the page shows it instead.
                    failures.append(viewModel.errorMessage ?? "Parakeet could not be installed.")
                    viewModel.errorMessage = nil
                }
            }

            let models = viewModel.speakerDiarizationModels
            if !models.isNemotronInstalled {
                await models.downloadNemotronModels()
            }
            if models.isNemotronInstalled && models.isInstalled {
                viewModel.automationSettings.diarizationEngine = "nemotron3"
                viewModel.automationSettings.speakerDiarizationEnabled = true
            } else {
                failures.append(models.nemotronStatusMessage ?? models.statusMessage ?? "Nemotron could not be installed.")
            }

            self.refreshModelState(viewModel)
            self.downloads = failures.isEmpty ? .done : .failed(failures.joined(separator: "\n"))
            self.downloadTask = nil
        }
    }

    /// After a failure: try again from where it stopped (installed models are skipped).
    func retryDownloads(_ viewModel: AppViewModel) {
        guard downloadTask == nil else { return }
        downloads = .notStarted
        startDownloads(viewModel)
    }

    // MARK: - Finishing

    /// Marks the setup done. With `restart`, MinuteMind quits and opens again with General shown.
    func finish(restart: Bool, viewModel: AppViewModel) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: Self.completedKey)
        defaults.removeObject(forKey: Self.stepKey)
        viewModel.ensureGeneralWorkspace()
        guard restart else {
            isActive = false
            viewModel.selectedProjectID = ProjectRepositoryService.generalProjectID
            return
        }
        defaults.set(true, forKey: Self.selectGeneralKey)
        Self.relaunch()
    }

    /// Whether this launch follows the setup's restart (General is selected once).
    static func consumeSelectGeneral() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: selectGeneralKey) else { return false }
        defaults.removeObject(forKey: selectGeneralKey)
        return true
    }

    /// Quits and reopens the app bundle. A small shell waits until this process is gone, so the
    /// new one is not handed back to the old one by Launch Services.
    static func relaunch() {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            let pid = ProcessInfo.processInfo.processIdentifier
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = [
                "-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", bundle.path,
            ]
            try? shell.run()
        }
        NSApp.terminate(nil)
    }
}
