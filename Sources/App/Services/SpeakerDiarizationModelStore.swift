// Purpose: Manages the on-device CoreML models used for speaker diarization (FluidAudio's
//          segmentation + speaker-embedding models). Provides install status and an explicit
//          one-time download with progress, so the first diarized transcription doesn't stall
//          silently on a large background download.
// Dependencies: FluidAudio (DiarizerModels download/caching).
// Used by: Sources/App/Views/AutomationSettingsView.swift (install UI),
//          Sources/App/ViewModels/AppViewModel.swift (gates whether a diarizer is created).
// Notes: FluidAudio's ModelHub caches the models on disk and DiarizerModels.downloadIfNeeded() is
//        idempotent, so this store only tracks *whether we have completed an install* via a marker
//        file, the same pattern ParakeetTranscriptionService uses for its model.

@preconcurrency import FluidAudio
import Foundation
import Observation

@Observable
@MainActor
final class SpeakerDiarizationModelStore {

    private(set) var isInstalled: Bool = false
    private(set) var isDownloading: Bool = false
    private(set) var downloadProgress: Double = 0
    private(set) var statusMessage: String?

    init() {
        refreshInstalledState()
    }

    // MARK: - Install marker

    private var markerURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("MinuteMind/diarization-models-installed")
    }

    func refreshInstalledState() {
        guard let markerURL else {
            isInstalled = false
            isNemotronInstalled = false
            return
        }
        isInstalled = FileManager.default.fileExists(atPath: markerURL.path)
        isNemotronInstalled = nemotronMarkerURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    private func writeInstalledMarker() {
        guard let markerURL else { return }
        try? FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: markerURL)
    }

    func removeInstalledMarker() {
        guard let markerURL else { return }
        try? FileManager.default.removeItem(at: markerURL)
        refreshInstalledState()
    }

    // MARK: - Nemotron 3

    /// Nemotron 3 has its own CoreML bundle on top of the base models (which still supply voice
    /// embeddings), so it is tracked with a separate marker.
    private(set) var isNemotronInstalled: Bool = false
    private(set) var isDownloadingNemotron: Bool = false
    private(set) var nemotronStatusMessage: String?

    private var nemotronMarkerURL: URL? {
        markerURL?.deletingLastPathComponent().appendingPathComponent("nemotron3-diarization-installed")
    }

    func downloadNemotronModels() async {
        guard !isDownloadingNemotron else { return }
        isDownloadingNemotron = true
        nemotronStatusMessage = "Downloading Nemotron 3…"
        defer { isDownloadingNemotron = false }

        if !isInstalled { await downloadModels() }
        do {
            _ = try await Nemotron3Models.loadFromHuggingFace(
                config: Nemotron3SpeakerDiarizer.config, computeUnits: .cpuAndNeuralEngine)
            if let url = nemotronMarkerURL {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data().write(to: url)
            }
            nemotronStatusMessage = nil
        } catch {
            nemotronStatusMessage = "Download failed: \(error.localizedDescription)"
        }
        refreshInstalledState()
    }

    // MARK: - Download

    func downloadModels() async {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        statusMessage = "Preparing…"
        defer { isDownloading = false }

        do {
            _ = try await DiarizerModels.downloadIfNeeded(progressHandler: { progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.downloadProgress = progress.fractionCompleted
                    switch progress.phase {
                    case .listing:
                        self.statusMessage = "Checking models…"
                    case .downloading(let completed, let total):
                        self.statusMessage = "Downloading model \(completed) of \(total)…"
                    case .compiling(let name):
                        self.statusMessage = "Compiling \(name)…"
                    }
                }
            })

            downloadProgress = 1.0
            statusMessage = nil
            writeInstalledMarker()
            refreshInstalledState()
            NSLog("SpeakerDiarizationModelStore: diarization models installed")
        } catch {
            statusMessage = "Download failed: \(error.localizedDescription)"
            NSLog("SpeakerDiarizationModelStore: download failed — \(error.localizedDescription)")
            refreshInstalledState()
        }
    }
}
