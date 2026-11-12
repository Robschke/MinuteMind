// Purpose: On-device transcription using NVIDIA Parakeet (Ultra, multilingual) via FluidAudio (CoreML,
//          Apple Neural Engine). The default transcription engine. The model must be explicitly installed
//          via downloadModel() before use; transcribe() throws modelNotInstalled otherwise. Also checks
//          Hugging Face for a newer revision of the model (checkForUpdate) and installs it side by side.
// Dependencies: FluidAudio (Apache 2.0), AVFoundation, Foundation
// Used by: Sources/App/ViewModels/AppViewModel.swift (parakeetService property, transcribeWithParakeet,
//          Parakeet model management), Sources/App/Services/QuickDictationService.swift (loadInstalledModels)
// Notes: - New installs use Parakeet Ultra (a post-training of TDT v3: same architecture and 25 European
//          languages, lower error rates). An existing v3 install keeps working and is offered the
//          update; the installed version is read from the marker, never assumed.
//        - Long-form audio uses ASRConfig(melChunkContext: false) per FluidAudio source guidance (avoids
//          English drift); FluidAudio applies the same v3-family default to Ultra.
//        - "Latest" means the newest commit of the model's Hugging Face repo. A different model family
//          (a successor to Ultra) needs a FluidAudio and app update; a button cannot fetch one.
//        - Each revision installs into its own folder (<FluidAudio Models>/minutemind-parakeet/<sha>/…),
//          pinned to that commit via ModelRegistry.revisionOverrides, so a failed update never touches the
//          working model. Older folders are pruned at the next launch (pruneStaleInstalls), not right
//          after an update, because a running transcription or dictation may still use them.
//        - The marker stores the exact folder URL; FluidAudio resolves the repo folder relative to the
//          passed URL, so the same URL must be reused for load()/modelsExist().
//        - AsrManager is an actor; transcribe() takes an inout TdtDecoderState and resamples file URLs to
//          16 kHz internally. Batch transcribe honors Task cancellation (throws CancellationError).
//        - Language is auto-detected (multilingual), so the language argument is currently ignored.
//        - Requires Apple Silicon (FluidAudio throws unsupportedPlatform on Intel).
//        - @unchecked Sendable following the project pattern for service objects.

import AVFoundation
import Foundation
import FluidAudio

final class ParakeetTranscriptionService: @unchecked Sendable {
    enum ServiceError: Error, LocalizedError {
        case noAudioFiles
        case mixingFailed(String)
        case modelLoadFailed(String)
        case modelNotInstalled

        var errorDescription: String? {
            switch self {
            case .noAudioFiles:
                return "No audio files found to transcribe"
            case .mixingFailed(let reason):
                return "Failed to prepare audio for Parakeet transcription: \(reason)"
            case .modelLoadFailed(let reason):
                return "Failed to load Parakeet model: \(reason)"
            case .modelNotInstalled:
                return "The Parakeet model is not installed. Go to Settings → Automation to install it."
            }
        }
    }

    /// Called on the MainActor with human-readable status during model loading or download.
    var onModelLoadProgress: ((String) -> Void)?
    /// Called on the MainActor with download fraction (0.0–1.0) during model download.
    var onDownloadProgress: ((Double) -> Void)?
    /// Called on the MainActor with (percentComplete, 100) during transcription of long audio.
    var onProgress: ((Int, Int) -> Void)?

    /// The model new installs and updates get.
    private static let currentVersion: AsrModelVersion = .ultra
    private static let currentRepo: Repo = .parakeetUltra

    /// What an update check found.
    enum UpdateStatus: Equatable {
        case upToDate
        /// The installed model is an older family (v3); `currentVersion` replaces it.
        case newModel
        /// The model's Hugging Face repo has a newer commit than the installed one.
        case newRevision
    }

    /// The installed model, as recorded by the marker.
    private struct Installation: Codable {
        var version: String
        var folder: String
        /// Hugging Face commit the files were downloaded from; nil when it could not be read.
        var revision: String?
        var installedAt: Date?

        var modelVersion: AsrModelVersion? {
            switch version {
            case "ultra": return .ultra
            case "v3": return .v3
            default: return nil
            }
        }
    }

    private var asrManager: AsrManager?

    init() {}

    // MARK: - Installation

    /// True when the model files exist on disk at the recorded location.
    var isModelInstalled: Bool {
        guard let installation, let version = installation.modelVersion else { return false }
        return AsrModels.modelsExist(at: URL(fileURLWithPath: installation.folder), version: version)
    }

    /// Display name of the installed model, nil when none is installed.
    var installedModelName: String? {
        guard isModelInstalled, let version = installation?.modelVersion else { return nil }
        return version == .ultra ? "Parakeet Ultra" : "Parakeet TDT v3"
    }

    /// When the installed revision was downloaded (nil for installs made before this was recorded).
    var installedAt: Date? { installation?.installedAt }

    /// What is on disk, for diagnostics (get_app_status): the marker, the folder it names, and
    /// whether the model files there are complete. A marker without complete files is a broken
    /// install that a new download repairs.
    struct InstallDiagnostics: Equatable, Sendable {
        var markerPresent: Bool
        var version: String?
        var folder: String?
        var folderExists: Bool
        var filesComplete: Bool
        var revision: String?
        var installedAt: Date?
        var loadedInMemory: Bool
    }

    var installDiagnostics: InstallDiagnostics {
        let installation = installation
        let folder = installation?.folder
        return InstallDiagnostics(
            markerPresent: installation != nil,
            version: installation?.version,
            folder: folder,
            folderExists: folder.map { FileManager.default.fileExists(atPath: $0) } ?? false,
            filesComplete: isModelInstalled,
            revision: installation?.revision,
            installedAt: installation?.installedAt,
            loadedInMemory: asrManager != nil
        )
    }

    /// Compares the installed model with the newest one available. Throws when Hugging Face
    /// cannot be reached; an older model family is reported without asking the network.
    func checkForUpdate() async throws -> UpdateStatus {
        guard let installation, isModelInstalled else { return .newModel }
        guard installation.modelVersion == Self.currentVersion else { return .newModel }
        let latest = try await Self.latestRevision()
        return installation.revision == latest ? .upToDate : .newRevision
    }

    /// Downloads the newest revision of the current model into its own folder and switches to it once
    /// complete; the previous model stays usable until then. Reports progress via onDownloadProgress.
    func downloadModel() async throws {
        await MainActor.run {
            onModelLoadProgress?("Downloading…")
            onDownloadProgress?(0)
        }

        // Box the callbacks so they can cross into the @Sendable progress closure.
        final class CallbackBox: @unchecked Sendable {
            var progress: ((Double) -> Void)?
            var status: ((String) -> Void)?
        }
        let box = CallbackBox()
        box.progress = onDownloadProgress
        box.status = onModelLoadProgress

        // Without the revision the download still works from "main"; the next check then offers it again.
        let revision = try? await Self.latestRevision()
        let target = Self.installRoot
            .appendingPathComponent(revision.map { String($0.prefix(12)) } ?? "main", isDirectory: true)
            .appendingPathComponent(Self.currentRepo.folderName, isDirectory: true)
        let remotePath = Self.currentRepo.remotePath
        if let revision { ModelRegistry.revisionOverrides[remotePath] = revision }
        defer { ModelRegistry.revisionOverrides[remotePath] = nil }

        let folder: URL
        do {
            folder = try await AsrModels.download(
                to: target, force: revision == nil, version: Self.currentVersion
            ) { progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    box.progress?(fraction)
                    if fraction < 1.0 {
                        box.status?("Downloading… \(Int(fraction * 100))%")
                    }
                }
            }
        } catch {
            NSLog("ParakeetTranscriptionService: download error: %@", error.localizedDescription)
            await MainActor.run {
                onDownloadProgress?(0)
                onModelLoadProgress?("")
            }
            throw ServiceError.modelLoadFailed(error.localizedDescription)
        }

        guard AsrModels.modelsExist(at: folder, version: Self.currentVersion) else {
            await MainActor.run {
                onDownloadProgress?(0)
                onModelLoadProgress?("")
            }
            throw ServiceError.modelLoadFailed(
                "Model downloaded but key files are missing. Please try again."
            )
        }

        try writeInstallation(Installation(
            version: "ultra", folder: folder.path, revision: revision, installedAt: Date()))
        asrManager = nil
        await MainActor.run {
            onDownloadProgress?(1.0)
            onModelLoadProgress?("")
        }
    }

    /// Unloads the in-memory model instance and removes all downloaded files.
    func unloadModel() {
        if let installation {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: installation.folder))
        }
        try? FileManager.default.removeItem(at: Self.installRoot)
        asrManager = nil
        removeMarkers()
    }

    /// Deletes model folders the marker no longer points to: earlier Ultra revisions and the v3 model
    /// an Ultra install replaced. Run at launch, before anything has loaded a model.
    func pruneStaleInstalls() {
        guard let installation, isModelInstalled else { return }
        let fileManager = FileManager.default
        let current = URL(fileURLWithPath: installation.folder).standardizedFileURL
        let revisions = (try? fileManager.contentsOfDirectory(
            at: Self.installRoot, includingPropertiesForKeys: nil)) ?? []
        for folder in revisions where !current.path.hasPrefix(folder.standardizedFileURL.path + "/") {
            try? fileManager.removeItem(at: folder)
        }
        if installation.modelVersion == .ultra {
            let legacy = AsrModels.defaultCacheDirectory(for: .v3)
            if fileManager.fileExists(atPath: legacy.path) { try? fileManager.removeItem(at: legacy) }
            legacyMarkerURL.map { try? fileManager.removeItem(at: $0) }
        }
    }

    /// Loads the installed Parakeet models so another engine can reuse them; quick dictation
    /// streams through its own manager but must not trigger a second download.
    func loadInstalledModels() async throws -> AsrModels {
        guard let dir = installedModelDirectory, let version = installation?.modelVersion else {
            throw ServiceError.modelNotInstalled
        }
        do {
            return try await AsrModels.load(from: dir, version: version)
        } catch {
            throw ServiceError.modelLoadFailed(error.localizedDescription)
        }
    }

    /// Newest commit of the current model's Hugging Face repo.
    private static func latestRevision() async throws -> String {
        struct ModelInfo: Decodable { let sha: String }
        guard let url = URL(string: "\(ModelRegistry.baseURL)/api/models/\(currentRepo.remotePath)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(ModelInfo.self, from: data).sha
    }

    // MARK: - Transcription

    /// Transcribes audio using the on-device Parakeet model.
    /// Throws `modelNotInstalled` if `downloadModel()` has not been called successfully.
    /// `language` is currently ignored: Parakeet is multilingual and auto-detects.
    func transcribe(
        microphoneURL: URL?,
        systemURL: URL?,
        language: String? = nil,
        prompt: String? = nil,
        diarization: DiarizationOptions? = nil
    ) async throws -> LabeledTranscript {
        guard isModelInstalled else { throw ServiceError.modelNotInstalled }

        let manager = try await loadModelIfNeeded()

        let micExists = microphoneURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let sysExists = systemURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        guard micExists || sysExists else { throw ServiceError.noAudioFiles }

        // Speaker-labeled path: transcribe each channel on its own so the microphone stays the
        // known local speaker ("You") while the mixed remote channel gets diarized into
        // "Speaker 1/2/…". Falls back to the plain mixed path below on any failure.
        if let diarization {
            do {
                if let labeled = try await transcribeWithSpeakers(
                    manager: manager,
                    microphoneURL: micExists ? microphoneURL : nil,
                    systemURL: sysExists ? systemURL : nil,
                    diarization: diarization)
                {
                    return labeled
                }
            } catch is CancellationError {
                throw TranscriptionInterruptedError(partialText: nil)
            } catch {
                NSLog(
                    "ParakeetTranscriptionService: speaker-labeled path failed (%@) — falling back to plain transcript",
                    error.localizedDescription)
            }
        }

        let audioURL: URL
        var tempURL: URL?

        if micExists && sysExists, let micURL = microphoneURL, let sysURL = systemURL {
            let mixed = try await mixAudio(mic: micURL, system: sysURL)
            audioURL = mixed
            tempURL = mixed
        } else if micExists, let micURL = microphoneURL {
            audioURL = micURL
        } else {
            audioURL = systemURL!
        }

        defer { tempURL.map { try? FileManager.default.removeItem(at: $0) } }

        // Observe the transcription progress stream (emits only for audio longer than ~15 s).
        // Must be obtained before calling transcribe(). Report as (percent, 100).
        let onProgressCopy = onProgress
        let progressStream = await manager.transcriptionProgressStream
        let progressObserver = Task { @MainActor in
            do {
                for try await fraction in progressStream {
                    onProgressCopy?(Int(fraction * 100), 100)
                }
            } catch {
                // Stream errors are surfaced by transcribe() itself; ignore here.
            }
        }
        defer { progressObserver.cancel() }

        // The v3 family uses 2 decoder layers (the default). A fresh state per file avoids carrying context over.
        var decoderState = TdtDecoderState.make()

        let result: ASRResult
        do {
            result = try await manager.transcribe(audioURL, decoderState: &decoderState)
        } catch is CancellationError {
            throw TranscriptionInterruptedError(partialText: nil)
        } catch {
            if Task.isCancelled {
                throw TranscriptionInterruptedError(partialText: nil)
            }
            throw error
        }

        if Task.isCancelled {
            let partial = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TranscriptionInterruptedError(partialText: partial.isEmpty ? nil : partial)
        }

        return LabeledTranscript(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Speaker-labeled transcription

    /// Transcribes each channel separately and assembles a speaker-labeled transcript:
    /// the microphone becomes "You", the mixed remote channel is diarized into "Speaker 1/2/…".
    /// Returns nil when Parakeet reported no word timings (caller falls back to plain text).
    private func transcribeWithSpeakers(
        manager: AsrManager,
        microphoneURL: URL?,
        systemURL: URL?,
        diarization: DiarizationOptions
    ) async throws -> LabeledTranscript? {
        var utterances: [TranscriptUtterance] = []
        var samples: [SpeakerSample] = []
        // Shared numbering so mic "Speaker 1" and system "Speaker 1" are never the same number.
        var labeler = SpeakerLabeler()

        if let micURL = microphoneURL {
            guard let words = try await timedWords(manager: manager, url: micURL) else { return nil }
            var micUtterances = TranscriptFormatting.groupIntoUtterances(
                words, speaker: TranscriptFormatting.localSpeaker, language: "auto")

            if diarization.includeMicrophone {
                let result = try await diarization.diarizer.diarize(
                    fileURL: micURL, expectedSpeakers: nil)
                let distinct = Set(result.turns.map(\.speaker)).count
                NSLog(
                    "ParakeetTranscriptionService: microphone %d words, %d turns, %d speakers",
                    words.count, result.turns.count, distinct)

                // Only split the mic when more than one person actually spoke into it; a single
                // cluster means the solo case, where "You" is the correct and more useful label.
                if distinct > 1 {
                    micUtterances = Self.applyLabels(
                        to: micUtterances, result: result, channel: "mic",
                        labeler: &labeler, fallback: TranscriptFormatting.localSpeaker)
                }
            } else {
                NSLog("ParakeetTranscriptionService: microphone %d words", words.count)
            }
            samples += SpeakerSampling.samples(
                from: micUtterances, channel: .microphone,
                embeddings: labeler.embeddingByLabel)
            utterances += micUtterances
        }

        if let sysURL = systemURL {
            guard let words = try await timedWords(manager: manager, url: sysURL) else { return nil }

            // Diarize the remote channel, then label each utterance by the turn it overlaps most.
            let systemUtterances = TranscriptFormatting.groupIntoUtterances(
                words, speaker: "Other", language: "auto")
            let result = try await diarization.diarizer.diarize(
                fileURL: sysURL, expectedSpeakers: nil)
            NSLog(
                "ParakeetTranscriptionService: system %d words, %d speaker turns",
                words.count, result.turns.count)

            let labeled =
                result.turns.isEmpty
                ? systemUtterances
                : Self.applyLabels(
                    to: systemUtterances, result: result, channel: "system",
                    labeler: &labeler, fallback: "Other")
            samples += SpeakerSampling.samples(
                from: labeled, channel: .system, embeddings: labeler.embeddingByLabel)
            utterances += labeled
        }

        guard !utterances.isEmpty else { return nil }
        return LabeledTranscript(
            text: TranscriptFormatting.assemble(utterances, showLanguage: false),
            speakers: samples)
    }

    /// Replaces each utterance's speaker with the diarized label for the turn it overlaps.
    private static func applyLabels(
        to utterances: [TranscriptUtterance],
        result: DiarizationResult,
        channel: String,
        labeler: inout SpeakerLabeler,
        fallback: String
    ) -> [TranscriptUtterance] {
        let labels = labeler.labels(
            forUtteranceRanges: utterances.map { (start: $0.start, duration: $0.duration) },
            result: result,
            channel: channel,
            fallbackLabel: fallback)
        return zip(utterances, labels).map { utterance, label in
            var labeled = utterance
            labeled.speaker = label
            return labeled
        }
    }

    /// Transcribes a single file and returns word-level timings, or nil when the model reported
    /// no token timings (some short/edge-case inputs).
    private func timedWords(manager: AsrManager, url: URL) async throws -> [TimedWord]? {
        var decoderState = TdtDecoderState.make()
        let result = try await manager.transcribe(url, decoderState: &decoderState)

        try Task.checkCancellation()

        guard let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty else {
            NSLog("ParakeetTranscriptionService: no token timings for %@", url.lastPathComponent)
            return nil
        }
        // FluidAudio groups SentencePiece sub-word tokens into words for us.
        return buildWordTimings(from: tokenTimings).map {
            TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
    }

    // MARK: - Private Helpers

    /// Loads the model from the recorded location without downloading.
    private func loadModelIfNeeded() async throws -> AsrManager {
        if let existing = asrManager { return existing }

        guard let dir = installedModelDirectory, let version = installation?.modelVersion else {
            throw ServiceError.modelNotInstalled
        }
        NSLog("ParakeetTranscriptionService.loadModelIfNeeded: loading from folder=%@", dir.path)

        await MainActor.run { onModelLoadProgress?("Loading Parakeet model…") }

        final class StatusBox: @unchecked Sendable { var status: ((String) -> Void)? }
        let box = StatusBox()
        box.status = onModelLoadProgress

        let models: AsrModels
        do {
            models = try await AsrModels.load(from: dir, version: version) { progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    box.status?("Loading model… \(Int(fraction * 100))%")
                }
            }
        } catch {
            await MainActor.run { onModelLoadProgress?("") }
            throw ServiceError.modelLoadFailed(error.localizedDescription)
        }

        // v3-family multilingual long-form audio: disable English-tuned mel chunk context to avoid drift.
        let manager = AsrManager(config: ASRConfig(melChunkContext: false))
        do {
            try await manager.loadModels(models)
        } catch {
            await MainActor.run { onModelLoadProgress?("") }
            throw ServiceError.modelLoadFailed(error.localizedDescription)
        }
        asrManager = manager

        await MainActor.run { onModelLoadProgress?("") }
        return manager
    }

    // MARK: - File Paths

    /// Parent of the per-revision model folders.
    private static var installRoot: URL {
        AsrModels.defaultCacheDirectory(for: currentVersion)
            .deletingLastPathComponent()
            .appendingPathComponent("minutemind-parakeet", isDirectory: true)
    }

    private var appSupportURL: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ).appendingPathComponent("MinuteMind")
    }

    /// Marker describing the installed model (version, folder, revision).
    private var markerURL: URL? { appSupportURL?.appendingPathComponent("parakeet-installed.json") }

    /// Marker of v3 installs, holding only the folder path.
    private var legacyMarkerURL: URL? { appSupportURL?.appendingPathComponent("parakeet-tdt-v3-installed") }

    private var installation: Installation? {
        if let url = markerURL, let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let installation = try? decoder.decode(Installation.self, from: data) { return installation }
        }
        guard let url = legacyMarkerURL,
              let path = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Installation(version: "v3", folder: path, revision: nil, installedAt: nil)
    }

    /// The installed model folder, or nil if not installed.
    var installedModelDirectory: URL? {
        installation.map { URL(fileURLWithPath: $0.folder) }
    }

    private func writeInstallation(_ installation: Installation) throws {
        guard let url = markerURL else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(installation).write(to: url, options: .atomic)
    }

    private func removeMarkers() {
        markerURL.map { try? FileManager.default.removeItem(at: $0) }
        legacyMarkerURL.map { try? FileManager.default.removeItem(at: $0) }
    }

    // MARK: - Audio Mixing

    /// Combines the microphone + system tracks into a single m4a for transcription.
    private func mixAudio(mic: URL, system: URL) async throws -> URL {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-pk-mixed.m4a")

        let composition = AVMutableComposition()
        let micAsset = AVURLAsset(url: mic)
        let sysAsset = AVURLAsset(url: system)

        let micTracks = try await micAsset.loadTracks(withMediaType: .audio)
        if let micTrack = micTracks.first,
           let compTrack = composition.addMutableTrack(
               withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let duration = try await micAsset.load(.duration)
            try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: micTrack, at: .zero)
        }

        let sysTracks = try await sysAsset.loadTracks(withMediaType: .audio)
        if let sysTrack = sysTracks.first,
           let compTrack = composition.addMutableTrack(
               withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let duration = try await sysAsset.load(.duration)
            try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sysTrack, at: .zero)
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)
        else { throw ServiceError.mixingFailed("Could not create audio exporter") }

        exporter.outputURL = outURL
        exporter.outputFileType = .m4a
        await exporter.export()

        if exporter.status != .completed {
            throw ServiceError.mixingFailed(
                exporter.error?.localizedDescription ?? "Export failed with status \(exporter.status.rawValue)"
            )
        }
        return outURL
    }
}
