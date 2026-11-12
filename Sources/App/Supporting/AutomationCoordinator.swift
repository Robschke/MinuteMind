// Purpose: AutomationCoordinator actor — single serialisation point for all automation triggers.
//          Polls calendar every 30 s, auto-starts recording for marked events, monitors audio
//          silence (the pill then asks whether the meeting is over; recordings never stop by
//          themselves), and runs the post-recording pipeline (transcription → meeting minutes).
// Dependencies: Sources/App/ViewModels/AppViewModel.swift (weak reference to orchestrator)
//               Sources/App/Config/AutomationSettings.swift
//               Sources/App/Services/AutoRecordStore.swift
//               Sources/App/Services/CalendarService.swift
//               Sources/App/Audio/MicRecorder.swift (via AppViewModel.currentMicLevel)
// Used by: Sources/App/ViewModels/AppViewModel.swift (automationCoordinator property)
// Notes: Swift actor for serial execution. @MainActor async methods on AppViewModel are
//        called directly with `await` — Swift hops to the main actor automatically.
//        The app must be running for scheduling to work — background launch is future work.
//        Silence = RMS < 0.01 (~-40 dBFS). autoStopSilenceThreshold 0 disables silence detection.

import Foundation

actor AutomationCoordinator {

    private weak var appViewModel: AppViewModel?
    /// Task driving the 30-second event-check loop.
    private var monitoringTask: Task<Void, Never>?
    /// Task polling mic level during an auto-triggered recording.
    private var silenceTask: Task<Void, Never>?
    /// Event IDs already triggered — prevents double-starts within the same ±60 s window.
    /// Persisted to UserDefaults so triggers survive app restarts.
    private var triggeredEventIDs: Set<String> = []
    private static let triggeredIDsKey = "automationTriggeredEventIDs"
    private static let triggeredTimestampsKey = "automationTriggeredTimestamps"
    /// Timestamps for each triggered event ID, used to prune stale entries.
    private var triggeredTimestamps: [String: Date] = [:]
    /// Tracks when each configured reminder time last fired a daily brief (key = "HH:mm").
    private var lastBriefRunByTime: [String: Date] = [:]
    /// The calendar day on which overdue tasks were last rolled forward (prevents repeated runs).
    private var lastRollForwardDay: Date?

    init(appViewModel: AppViewModel) {
        self.appViewModel = appViewModel

        // Restore persisted triggered IDs, pruning entries older than 2 hours.
        let storedIDs = UserDefaults.standard.stringArray(forKey: Self.triggeredIDsKey) ?? []
        let storedTimestamps = UserDefaults.standard.dictionary(forKey: Self.triggeredTimestampsKey) as? [String: Date] ?? [:]
        let cutoff = Date().addingTimeInterval(-2 * 60 * 60)
        for id in storedIDs {
            if let ts = storedTimestamps[id], ts > cutoff {
                triggeredEventIDs.insert(id)
                triggeredTimestamps[id] = ts
            }
        }
    }

    // MARK: - Lifecycle

    func startMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            await self?.eventMonitorLoop()
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        stopSilenceMonitoring()
    }

    private func stopSilenceMonitoring() {
        silenceTask?.cancel()
        silenceTask = nil
    }

    // MARK: - Event Monitor Loop

    private func eventMonitorLoop() async {
        while !Task.isCancelled {
            await checkAndTriggerRecording()
            await checkAndRunDailyBrief()
            await checkAndRollForwardOverdueTasks()
            try? await Task.sleep(for: .seconds(30))
        }
    }

    // MARK: - Daily Task Brief

    /// Fires the AI-powered daily task brief when the clock matches a configured reminder time.
    /// Uses a 50-minute cooldown per time slot to prevent double-triggering across poll cycles.
    private func checkAndRunDailyBrief() async {
        guard let vm = appViewModel else { return }

        let reminderTimes = await MainActor.run { vm.automationSettings.reviewReminderTimes }
        guard !reminderTimes.isEmpty else { return }

        let now = Date()
        let cal = Calendar.current
        let currentHour   = cal.component(.hour,   from: now)
        let currentMinute = cal.component(.minute, from: now)

        for components in reminderTimes {
            guard let hour = components.hour, let minute = components.minute else { continue }
            guard hour == currentHour, minute == currentMinute else { continue }

            let key = "\(hour):\(String(format: "%02d", minute))"
            if let last = lastBriefRunByTime[key], now.timeIntervalSince(last) < 50 * 60 { continue }
            lastBriefRunByTime[key] = now

            NSLog("AutomationCoordinator: Triggering daily task brief for scheduled time %@", key)
            await vm.runTodoBrief()
        }
    }

    /// Rolls forward overdue tasks once per calendar day while the app is running.
    private func checkAndRollForwardOverdueTasks() async {
        let todayStart = Calendar.current.startOfDay(for: Date())
        if let last = lastRollForwardDay, last >= todayStart { return }
        lastRollForwardDay = todayStart
        guard let vm = appViewModel else { return }
        await vm.rollForwardOverdueTasks()
    }

    private func checkAndTriggerRecording() async {
        guard let vm = appViewModel else { return }

        let autoStartEnabled = await MainActor.run { vm.automationSettings.autoStartEnabled }
        let isRecording = await MainActor.run { vm.isRecording }
        guard autoStartEnabled, !isRecording else { return }

        let now = Date()
        // Consider events whose start time falls within ±60 seconds of now.
        let windowStart = now.addingTimeInterval(-60)
        let windowEnd = now.addingTimeInterval(60)

        let events = await MainActor.run {
            vm.calendarService.fetchEvents(from: windowStart, to: windowEnd)
        }

        // Prune triggered IDs for events that have left the window (prevent indefinite growth).
        let windowIDs = Set(events.map(\.id))
        let pruned = triggeredEventIDs.subtracting(windowIDs)
        if !pruned.isEmpty {
            triggeredEventIDs.subtract(pruned)
            for id in pruned { triggeredTimestamps.removeValue(forKey: id) }
            persistTriggeredIDs()
        }

        for event in events {
            guard !triggeredEventIDs.contains(event.id) else { continue }

            // Skip all-day events (not real meetings).
            guard !event.isAllDay else {
                NSLog("AutomationCoordinator: Skipping all-day event '\(event.title)'")
                continue
            }

            // Skip declined events.
            guard event.participantStatus != .declined else {
                NSLog("AutomationCoordinator: Skipping declined event '\(event.title)'")
                continue
            }

            let isEnabled = await MainActor.run { vm.autoRecordStore.isEnabled(for: event.id) }
            guard isEnabled else {
                // Not opted in to auto-record: offer it through the meeting pill instead, once.
                triggeredEventIDs.insert(event.id)
                triggeredTimestamps[event.id] = Date()
                persistTriggeredIDs()
                await MainActor.run { vm.promptForCalendarEvent(event) }
                continue
            }

            // Insert before any further await to prevent concurrent double-triggers.
            triggeredEventIDs.insert(event.id)
            triggeredTimestamps[event.id] = Date()
            persistTriggeredIDs()

            let threshold = await MainActor.run { vm.automationSettings.autoStopSilenceThreshold }
            NSLog("AutomationCoordinator: Auto-starting recording for '\(event.title)'")

            // Set the pending event (title + calendar metadata + project assignment) then record.
            await MainActor.run {
                vm.pendingSessionTitle = event.title
                vm.pendingCalendarEvent = event
            }
            await vm.startRecording()

            let sessionID = await MainActor.run { vm.currentSession?.id }

            if threshold > 0, let sid = sessionID {
                startSilenceMonitoring(threshold: threshold, sessionID: sid)
            }

            break // Only one recording can be started per poll cycle.
        }
    }

    // MARK: - Triggered ID Persistence

    private func persistTriggeredIDs() {
        UserDefaults.standard.set(Array(triggeredEventIDs), forKey: Self.triggeredIDsKey)
        UserDefaults.standard.set(triggeredTimestamps, forKey: Self.triggeredTimestampsKey)
    }

    // MARK: - Silence Monitoring

    /// Public entry point so callers (e.g. manual recordings) can trigger silence monitoring.
    func startSilenceMonitoringIfNeeded(threshold: Double, sessionID: UUID) {
        guard threshold > 0 else { return }
        startSilenceMonitoring(threshold: threshold, sessionID: sessionID)
    }

    private func startSilenceMonitoring(threshold: Double, sessionID: UUID) {
        stopSilenceMonitoring()
        silenceTask = Task { [weak self] in
            await self?.silenceMonitorLoop(threshold: threshold, sessionID: sessionID)
        }
    }

    private func silenceMonitorLoop(threshold: Double, sessionID: UUID) async {
        let pollInterval: TimeInterval = 5
        let silenceRMSThreshold: Float = 0.01
        /// Don't start checking silence until the recording has been running this long.
        /// Prevents stopping a recording that's still in the "everyone joining" phase.
        let minimumRecordingDuration: TimeInterval = 60
        var silenceDuration: TimeInterval = 0
        var totalElapsed: TimeInterval = 0
        var effectiveThreshold = threshold

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(pollInterval))
            guard let vm = appViewModel else { return }

            let isRecording = await MainActor.run { vm.isRecording }
            guard isRecording else {
                NSLog("AutomationCoordinator: Recording stopped externally — silence monitor exiting")
                return
            }

            totalElapsed += pollInterval

            // Don't evaluate silence until the recording has been running long enough.
            guard totalElapsed >= minimumRecordingDuration else { continue }

            // Both sides count: listening quietly while others talk is not silence.
            let level = await MainActor.run { vm.currentCallLevel }
            if level < silenceRMSThreshold {
                silenceDuration += pollInterval
                if silenceDuration.truncatingRemainder(dividingBy: 30) < pollInterval {
                    // Log every ~30 seconds to avoid spam.
                    NSLog("AutomationCoordinator: Silence \(Int(silenceDuration))s / \(Int(threshold))s (RMS \(String(format: "%.4f", level)))")
                }
            } else {
                silenceDuration = 0
            }

            guard silenceDuration >= effectiveThreshold else { continue }

            // Silence is a weak end signal: the pill asks, the user decides.
            NSLog("AutomationCoordinator: Silence threshold reached, asking whether the meeting ended")
            await vm.handleSilenceDetected(silence: silenceDuration)
            silenceDuration = 0
            // If the user keeps recording, ask again only after twice as much silence.
            effectiveThreshold = min(effectiveThreshold * 2, 30 * 60)
        }
    }

    // MARK: - Auto Pipeline

    /// Public entry point so callers (e.g. Teams auto-recording) can trigger the pipeline.
    /// Enqueues the transcription; processing follows only when MeetingProcessingRule allows it
    /// (the meeting has a project and named speakers).
    func runPipelineIfEnabled(for sessionID: UUID) async {
        guard let vm = appViewModel else { return }

        // Engine choice (and the fallback when its model is missing) lives on AppViewModel, so the
        // Transcribe button and this auto-pipeline can never disagree about what "default" means.
        // Language stays auto-detect here — an unattended recording has no UI selection behind it.
        await MainActor.run {
            let queueModel = vm.configuredTranscriptionModel(language: .auto)
            NSLog("AutomationCoordinator: Enqueuing transcription, engine=\(vm.configuredTranscriptionEngineName)")
            if let note = vm.transcriptionEngineFallbackNote {
                NSLog("AutomationCoordinator: \(note)")
            }

            vm.enqueueTranscription(sessionID: sessionID, model: queueModel)
        }
    }
}
