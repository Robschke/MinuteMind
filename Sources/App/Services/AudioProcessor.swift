// Purpose: Audio processing — streaming waveform generation, VAD, and cropping.
//          Waveform generation streams audio in chunks to stay memory-efficient even for
//          multi-hour recordings. Heavy I/O runs off the main actor to keep UI responsive.
//          Supports cooperative Task cancellation.
// Dependencies: AVFoundation, Accelerate
// Used by: Sources/App/ViewModels/AppViewModel.swift (generateWaveform, cropAudio)

import AVFoundation
import Accelerate

/// Service for audio processing: waveform generation, VAD, and cropping
@MainActor
class AudioProcessor {

    /// Single shared queue for M4A transcoding — prevents thread explosion when migrating many sessions.
    private static let m4aQueue = DispatchQueue(label: "AudioProcessor.m4a", qos: .utility)

    struct WaveformData: Sendable {
        let samples: [Float]  // Normalized amplitude values (0.0 to 1.0)
        let duration: TimeInterval
        let sampleRate: Int  // Samples per second of waveform (not audio sample rate)
        let speechSegments: [SpeechSegment]
    }

    struct SpeechSegment: Sendable {
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    /// Generate waveform data from audio file.
    ///
    /// Heavy I/O runs on a background thread — the main actor is free for UI.
    /// Streams audio in chunks — memory usage is O(targetSamples), not O(fileSize).
    /// Respects cooperative Task cancellation between chunks.
    func generateWaveform(from url: URL, targetSamples: Int = 500) async throws -> WaveformData {
        try await Self.generateWaveformOffMain(from: url, targetSamples: targetSamples)
    }

    /// All heavy I/O happens here, off the main actor.
    private nonisolated static func generateWaveformOffMain(
        from url: URL, targetSamples: Int
    ) async throws -> WaveformData {
        let asset = AVAsset(url: url)

        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NSError(domain: "AudioProcessor", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio track found"])
        }

        // Read audio data
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)

        guard reader.startReading() else {
            throw NSError(domain: "AudioProcessor", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to start reading audio"])
        }

        // Get sample rate from format description (default 44100 Hz).
        let formatDescriptions = try await track.load(.formatDescriptions)
        let audioSampleRate: Double
        if let desc = formatDescriptions.first {
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
            audioSampleRate = asbd?.pointee.mSampleRate ?? 44100
        } else {
            audioSampleRate = 44100
        }

        // Per-chunk RMS accumulators — one entry per reader chunk.
        // We avoid pre-computing bucket distribution from asset duration metadata
        // because .caf files may not have finalised headers when read immediately
        // after recording stops, causing incorrect duration → broken bucketing.
        // Instead we collect per-chunk RMS and downsample after reading all data.
        struct ChunkRMS {
            var sumOfSquares: Double = 0
            var count: Int = 0
        }
        var chunkRMSValues: [ChunkRMS] = []

        // VAD accumulators — fixed-size sliding window, no retained sample array.
        let vadHopSamples = 2205 // ~50ms at 44.1kHz
        let vadThreshold: Float = 0.02
        let minSpeechDuration: TimeInterval = 0.3
        var vadEnergy: Float = 0
        var vadCount: Int = 0
        var vadSampleOffset: Int = 0  // global sample index for VAD window start
        var vadCurrentSegmentStart: TimeInterval?
        var speechSegments: [SpeechSegment] = []

        var globalSampleIndex = 0
        var chunkCounter = 0

        while reader.status == .reading {
            // Check cancellation every 64 chunks to stay responsive.
            chunkCounter += 1
            if chunkCounter % 64 == 0 {
                try Task.checkCancellation()
                await Task.yield()
            }

            guard let sampleBuffer = output.copyNextSampleBuffer(),
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                break
            }

            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = Data(count: length)
            _ = data.withUnsafeMutableBytes { buffer in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
            }

            var chunkRMS = ChunkRMS()

            data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                let buffer = ptr.bindMemory(to: Int16.self)

                for i in 0..<buffer.count {
                    let sample = buffer[i]
                    let normalized = Double(sample) / Double(Int16.max)

                    // Accumulate per-chunk energy
                    chunkRMS.sumOfSquares += normalized * normalized
                    chunkRMS.count += 1

                    // VAD accumulation
                    let floatNorm = Float(sample) / Float(Int16.max)
                    vadEnergy += floatNorm * floatNorm
                    vadCount += 1

                    if vadCount >= vadHopSamples {
                        let windowEnergy = vadEnergy / Float(vadCount)
                        let currentTime = Double(vadSampleOffset) / audioSampleRate

                        if windowEnergy > vadThreshold {
                            if vadCurrentSegmentStart == nil {
                                vadCurrentSegmentStart = currentTime
                            }
                        } else {
                            if let start = vadCurrentSegmentStart {
                                if currentTime - start >= minSpeechDuration {
                                    speechSegments.append(SpeechSegment(startTime: start, endTime: currentTime))
                                }
                                vadCurrentSegmentStart = nil
                            }
                        }

                        vadSampleOffset += vadCount
                        vadEnergy = 0
                        vadCount = 0
                    }

                    globalSampleIndex += 1
                }
            }

            if chunkRMS.count > 0 {
                chunkRMSValues.append(chunkRMS)
            }
        }

        // Derive duration from actual sample count — independent of asset metadata.
        let duration = Double(globalSampleIndex) / audioSampleRate

        // Close last VAD segment if still open
        if let start = vadCurrentSegmentStart {
            speechSegments.append(SpeechSegment(startTime: start, endTime: duration))
        }

        // Downsample per-chunk RMS into targetSamples waveform buckets.
        // Each chunk maps to buckets proportionally based on its sample count.
        let waveformSamples: [Float]
        if chunkRMSValues.isEmpty || globalSampleIndex == 0 {
            waveformSamples = [Float](repeating: 0, count: targetSamples)
        } else {
            var bucketSumOfSquares = [Double](repeating: 0, count: targetSamples)
            var bucketCounts = [Int](repeating: 0, count: targetSamples)

            var sampleOffset = 0
            for chunk in chunkRMSValues {
                // Map the chunk's midpoint to a bucket index
                let midpoint = sampleOffset + chunk.count / 2
                let bucketIndex = min(midpoint * targetSamples / globalSampleIndex, targetSamples - 1)
                bucketSumOfSquares[bucketIndex] += chunk.sumOfSquares
                bucketCounts[bucketIndex] += chunk.count
                sampleOffset += chunk.count
            }

            waveformSamples = (0..<targetSamples).map { i in
                guard bucketCounts[i] > 0 else { return Float(0) }
                let rms = sqrt(bucketSumOfSquares[i] / Double(bucketCounts[i]))
                return Float(min(rms, 1.0))
            }
        }

        let waveformSampleRate = duration > 0 ? Int(Double(targetSamples) / duration) : 1

        return WaveformData(
            samples: waveformSamples,
            duration: duration,
            sampleRate: waveformSampleRate,
            speechSegments: speechSegments
        )
    }

    /// Convert an audio file (e.g. PCM .caf) to AAC .m4a using AVAssetReader + AVAssetWriter.
    /// This is more reliable than AVAssetExportSession for edge-case PCM formats (e.g. 16 kHz
    /// mono .caf from SystemAudioRecorder). Returns the URL of the newly created .m4a file.
    func convertToM4A(from sourceURL: URL) async throws -> URL {
        let destinationURL = sourceURL.deletingPathExtension().appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: destinationURL)

        let asset = AVAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw NSError(domain: "AudioProcessor", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "No audio track in source file"])
        }

        NSLog("AudioProcessor: Converting \(sourceURL.lastPathComponent) → M4A via reader/writer")

        // Reader: decode to PCM float so we normalise any source format
        let reader = try AVAssetReader(asset: asset)
        let readerOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: readerOutputSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw NSError(domain: "AudioProcessor", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add reader output"])
        }
        reader.add(readerOutput)

        // Detect source sample rate and channels from the track
        let formatDescriptions = try await audioTrack.load(.formatDescriptions)
        let sourceFormat = formatDescriptions.first.flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
        }
        let sampleRate = sourceFormat?.mSampleRate ?? 44100
        let channels = sourceFormat.map { Int($0.mChannelsPerFrame) } ?? 1

        // Writer: AAC at 128 kbps
        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .m4a)
        let writerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 128_000,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw NSError(domain: "AudioProcessor", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add writer input"])
        }
        writer.add(writerInput)

        // Transcode
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerInput.requestMediaDataWhenReady(on: AudioProcessor.m4aQueue) {
                while writerInput.isReadyForMoreMediaData {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sampleBuffer)
                    } else {
                        writerInput.markAsFinished()
                        if reader.status == .failed {
                            writer.cancelWriting()
                            continuation.resume(throwing: reader.error ?? NSError(
                                domain: "AudioProcessor", code: 11,
                                userInfo: [NSLocalizedDescriptionKey: "Reader failed"]))
                        } else {
                            writer.finishWriting {
                                if writer.status == .failed {
                                    continuation.resume(throwing: writer.error ?? NSError(
                                        domain: "AudioProcessor", code: 11,
                                        userInfo: [NSLocalizedDescriptionKey: "Writer failed"]))
                                } else {
                                    continuation.resume()
                                }
                            }
                        }
                        return
                    }
                }
            }
        }

        // Validate: output must exist and have a reasonable size (at least 1 KB)
        let attrs = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
        let fileSize = (attrs[.size] as? UInt64) ?? 0
        guard fileSize >= 1024 else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw NSError(domain: "AudioProcessor", code: 14,
                          userInfo: [NSLocalizedDescriptionKey: "Converted M4A is too small (\(fileSize) bytes) — likely corrupt"])
        }

        NSLog("AudioProcessor: M4A conversion completed — \(destinationURL.lastPathComponent) (\(fileSize / 1024) KB)")
        return destinationURL
    }

    /// Re-encode an existing audio file in place to low-bitrate mono AAC (32 kbps) to reclaim disk
    /// space on archived recordings. Stereo is downmixed to mono and the sample rate is capped at
    /// 22.05 kHz — speech stays clearly intelligible. This is lossy and NOT reversible.
    /// Returns the number of bytes freed (original size − new size); 0 if the file was already smaller.
    func recompressForArchive(at url: URL) async throws -> Int64 {
        let originalSize = fileSize(at: url)
        let tempURL = url.deletingPathExtension().appendingPathExtension("archiving.m4a")
        try? FileManager.default.removeItem(at: tempURL)

        let asset = AVAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw NSError(domain: "AudioProcessor", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "No audio track to recompress"])
        }

        // Mono channel layout — required when forcing a channel count that differs from the source.
        var monoLayout = AudioChannelLayout()
        monoLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let layoutData = Data(bytes: &monoLayout, count: MemoryLayout<AudioChannelLayout>.size)

        // Reader: decode to mono PCM (CoreAudio downmixes during decode).
        let reader = try AVAssetReader(asset: asset)
        let readerOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVChannelLayoutKey: layoutData,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: readerOutputSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw NSError(domain: "AudioProcessor", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add reader output"])
        }
        reader.add(readerOutput)

        let formatDescriptions = try await audioTrack.load(.formatDescriptions)
        let sourceSampleRate = formatDescriptions.first.flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate
        } ?? 44100
        let targetSampleRate = min(sourceSampleRate, 22050)

        // Writer: mono AAC at 32 kbps.
        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .m4a)
        let writerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVChannelLayoutKey: layoutData,
            AVEncoderBitRateKey: 32_000,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw NSError(domain: "AudioProcessor", code: 22,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add writer input"])
        }
        writer.add(writerInput)

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerInput.requestMediaDataWhenReady(on: AudioProcessor.m4aQueue) {
                while writerInput.isReadyForMoreMediaData {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sampleBuffer)
                    } else {
                        writerInput.markAsFinished()
                        if reader.status == .failed {
                            writer.cancelWriting()
                            continuation.resume(throwing: reader.error ?? NSError(
                                domain: "AudioProcessor", code: 23,
                                userInfo: [NSLocalizedDescriptionKey: "Reader failed"]))
                        } else {
                            writer.finishWriting {
                                if writer.status == .failed {
                                    continuation.resume(throwing: writer.error ?? NSError(
                                        domain: "AudioProcessor", code: 23,
                                        userInfo: [NSLocalizedDescriptionKey: "Writer failed"]))
                                } else {
                                    continuation.resume()
                                }
                            }
                        }
                        return
                    }
                }
            }
        }

        let newSize = fileSize(at: tempURL)
        // Bail out if the result is corrupt or somehow not smaller — keep the original untouched.
        guard newSize >= 1024 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw NSError(domain: "AudioProcessor", code: 24,
                          userInfo: [NSLocalizedDescriptionKey: "Recompressed file too small (\(newSize) bytes) — likely corrupt"])
        }
        guard newSize < originalSize else {
            try? FileManager.default.removeItem(at: tempURL)
            return 0
        }

        // Replace the original atomically.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tempURL, to: url)
        NSLog("AudioProcessor: Recompressed \(url.lastPathComponent) \(originalSize / 1024) KB → \(newSize / 1024) KB")
        return max(0, originalSize - newSize)
    }

    /// File size in bytes, or 0 if the file is missing/unreadable.
    private func fileSize(at url: URL) -> Int64 {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return 0 }
        return Int64(size)
    }

    /// Crop audio file to specified time range
    func cropAudio(from sourceURL: URL, to destinationURL: URL, startTime: TimeInterval, endTime: TimeInterval) async throws {
        let asset = AVAsset(url: sourceURL)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "AudioProcessor", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }

        exportSession.outputURL = destinationURL
        exportSession.outputFileType = .m4a

        let start = CMTime(seconds: startTime, preferredTimescale: 600)
        let end = CMTime(seconds: endTime, preferredTimescale: 600)
        exportSession.timeRange = CMTimeRange(start: start, end: end)

        NSLog("AudioProcessor: Starting audio crop export from \(startTime)s to \(endTime)s")
        await exportSession.export()

        // Note: AVAssetExportSession may log internal MediaToolbox warnings/errors
        // to the system log (e.g., "FigExportCommmon signalled err=-12785") but
        // these are often benign and the export still completes successfully.
        // Only throw an error if the export session status indicates actual failure.

        switch exportSession.status {
        case .completed:
            NSLog("AudioProcessor: Audio crop completed successfully")
        case .failed:
            let errorDesc = exportSession.error?.localizedDescription ?? "Unknown error"
            NSLog("AudioProcessor: Audio crop failed: \(errorDesc)")
            throw NSError(domain: "AudioProcessor", code: 4, userInfo: [NSLocalizedDescriptionKey: "Export failed: \(errorDesc)"])
        case .cancelled:
            NSLog("AudioProcessor: Audio crop was cancelled")
            throw NSError(domain: "AudioProcessor", code: 5, userInfo: [NSLocalizedDescriptionKey: "Export was cancelled"])
        default:
            NSLog("AudioProcessor: Audio crop ended with unexpected status: \(exportSession.status.rawValue)")
            throw NSError(domain: "AudioProcessor", code: 6, userInfo: [NSLocalizedDescriptionKey: "Export ended with unexpected status"])
        }
    }
}
