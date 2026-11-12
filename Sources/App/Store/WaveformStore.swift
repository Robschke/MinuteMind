// Purpose: Per-session waveform sidecar storage. Each session's waveform samples
//          and speech segments live in their own compact binary file under
//          Waveforms/<id>.wf — keeping them OUT of sessions.json so the main
//          sessions store doesn't pay Float→ASCII encoding cost on every save.
// Dependencies: Foundation
// Used by: Sources/App/ViewModels/AppViewModel.swift (generateWaveform, deleteAllArtifacts,
//          cropAudio, restoreOriginalAudio, migrateWaveformsToSidecar)
// Notes: Binary format (little-endian, host byte order on Apple platforms):
//          - 4 bytes  magic "WAVF" (0x46564157 LE)
//          - 1 byte   version (1)
//          - 1 byte   channel (0=mic, 1=system)
//          - 2 bytes  reserved (0)
//          - 8 bytes  duration (Float64)
//          - 4 bytes  sampleCount (UInt32)
//          - 4 bytes  segmentCount (UInt32)
//          - 4 × sampleCount  Float32 samples
//          - 16 × segmentCount  (Float64 start, Float64 end) pairs
//        For 500 samples + 50 segments → ~2.8 KB. No Float→ASCII anywhere.

import Foundation

struct WaveformSidecar: Equatable {
    var samples: [Float]
    var duration: TimeInterval
    var speechSegments: [(start: TimeInterval, end: TimeInterval)]
    var channel: String  // "microphone" or "system"

    static func == (lhs: WaveformSidecar, rhs: WaveformSidecar) -> Bool {
        guard lhs.samples == rhs.samples,
              lhs.duration == rhs.duration,
              lhs.channel == rhs.channel,
              lhs.speechSegments.count == rhs.speechSegments.count else { return false }
        for (a, b) in zip(lhs.speechSegments, rhs.speechSegments) {
            if a.start != b.start || a.end != b.end { return false }
        }
        return true
    }
}

final class WaveformStore {
    private static let magic: UInt32 = 0x46564157  // "WAVF" little-endian
    private static let version: UInt8 = 1

    private let directory: URL
    private let fileManager: FileManager

    init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.directory = baseDirectory.appendingPathComponent("Waveforms", isDirectory: true)
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private func url(for sessionID: UUID) -> URL {
        directory.appendingPathComponent("\(sessionID.uuidString).wf")
    }

    func exists(sessionID: UUID) -> Bool {
        fileManager.fileExists(atPath: url(for: sessionID).path)
    }

    func load(sessionID: UUID) -> WaveformSidecar? {
        let fileURL = url(for: sessionID)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return decode(data)
    }

    func save(sessionID: UUID, _ sidecar: WaveformSidecar) throws {
        let data = encode(sidecar)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(for: sessionID), options: .atomic)
    }

    func delete(sessionID: UUID) {
        try? fileManager.removeItem(at: url(for: sessionID))
    }

    // MARK: - Binary codec

    private func encode(_ s: WaveformSidecar) -> Data {
        let sampleCount = UInt32(s.samples.count)
        let segmentCount = UInt32(s.speechSegments.count)
        let channelByte: UInt8 = s.channel == "system" ? 1 : 0

        var data = Data()
        data.reserveCapacity(24 + Int(sampleCount) * 4 + Int(segmentCount) * 16)

        var magic = Self.magic
        withUnsafeBytes(of: &magic) { data.append(contentsOf: $0) }
        var version = Self.version
        withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
        var channel = channelByte
        withUnsafeBytes(of: &channel) { data.append(contentsOf: $0) }
        var reserved: UInt16 = 0
        withUnsafeBytes(of: &reserved) { data.append(contentsOf: $0) }
        var duration = s.duration
        withUnsafeBytes(of: &duration) { data.append(contentsOf: $0) }
        var sc = sampleCount
        withUnsafeBytes(of: &sc) { data.append(contentsOf: $0) }
        var gc = segmentCount
        withUnsafeBytes(of: &gc) { data.append(contentsOf: $0) }

        s.samples.withUnsafeBufferPointer { buf in
            data.append(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
        }
        for seg in s.speechSegments {
            var start = seg.start
            var end = seg.end
            withUnsafeBytes(of: &start) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &end) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func decode(_ data: Data) -> WaveformSidecar? {
        guard data.count >= 24 else { return nil }

        let magic: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        guard magic == Self.magic else { return nil }

        let version: UInt8 = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt8.self) }
        guard version == Self.version else { return nil }

        let channelByte: UInt8 = data.withUnsafeBytes { $0.load(fromByteOffset: 5, as: UInt8.self) }
        let duration: TimeInterval = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Float64.self) }
        let sampleCount: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
        let segmentCount: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self) }

        let samplesStart = 24
        let samplesEnd = samplesStart + Int(sampleCount) * 4
        let segmentsEnd = samplesEnd + Int(segmentCount) * 16
        guard data.count >= segmentsEnd else { return nil }

        var samples = [Float](repeating: 0, count: Int(sampleCount))
        samples.withUnsafeMutableBufferPointer { buf in
            _ = data.copyBytes(to: buf, from: samplesStart..<samplesEnd)
        }

        var segments: [(start: TimeInterval, end: TimeInterval)] = []
        segments.reserveCapacity(Int(segmentCount))
        for i in 0..<Int(segmentCount) {
            let off = samplesEnd + i * 16
            let start: Float64 = data.withUnsafeBytes { $0.load(fromByteOffset: off, as: Float64.self) }
            let end: Float64 = data.withUnsafeBytes { $0.load(fromByteOffset: off + 8, as: Float64.self) }
            segments.append((start, end))
        }

        return WaveformSidecar(
            samples: samples,
            duration: duration,
            speechSegments: segments,
            channel: channelByte == 1 ? "system" : "microphone"
        )
    }
}
