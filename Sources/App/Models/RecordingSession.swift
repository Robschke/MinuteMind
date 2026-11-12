// Purpose: RecordingSession model — core data type for a recorded meeting session.
// Dependencies: Foundation
// Used by: Sources/App/ViewModels/AppViewModel.swift, Sources/App/Store/RecordingStore.swift,
//          all Views that display session data
// Notes: All fields added after initial release must be Optional for Codable backward compatibility
//        (legacy sessions.json files without those keys decode without crash).
//        Long-running work (transcription, audio conversion) writes back only the fields it owns
//        (takeTranscriptionResult, takeConvertedAudio), never its whole starting copy.

import Foundation

struct RecordingSession: Identifiable, Codable, Equatable {
    enum Status: String, Codable {
        case idle
        case recording
        case recorded
        case transcribing
        case liveTranscribing
        case completed
        case failed

        var isActive: Bool {
            switch self {
            case .recording, .transcribing, .liveTranscribing:
                return true
            default:
                return false
            }
        }
    }

    struct Transcript: Codable, Equatable {
        var text: String
        var languageCode: String
        var updatedAt: Date
        var fileName: String?
        /// The transcript as the engine produced it, kept when an AI cleanup rewrote `text`
        /// so the result can be compared against — or reverted to — the original.
        /// Nil when no cleanup has run. Optional, so existing sessions decode unchanged.
        var rawText: String?
    }
    
    /// A speaker detected by diarization, with a short representative audio range the user can
    /// listen to in order to put a name to the voice. Created during transcription; `name` is
    /// filled in later from the speaker-naming sheet.
    struct SpeakerProfile: Codable, Equatable, Identifiable {
        /// The generated label as it appears in the transcript, e.g. "Speaker 2".
        var label: String
        /// User-assigned display name. Nil until named.
        var name: String?
        /// Which recording the sample range refers to.
        var channel: Channel
        var sampleStart: TimeInterval
        var sampleEnd: TimeInterval
        /// Voice embedding for this speaker, used to recognise them in other recordings.
        /// Nil when the diarizer produced none. Optional, so existing sessions decode unchanged.
        var embedding: [Float]?
        /// The voice library entry this speaker was matched to or named as.
        var voiceID: UUID?
        /// True when `name` came from the voice library rather than from the user typing it here —
        /// the naming sheet marks these so a wrong automatic match is easy to spot.
        var wasAutoMatched: Bool?
        /// Total time this speaker talked in the recording.
        var spokenSeconds: TimeInterval?

        var id: String { label }
        var sampleDuration: TimeInterval { max(0, sampleEnd - sampleStart) }
        /// What the transcript currently shows for this speaker.
        var displayLabel: String { name ?? label }

        // MARK: - Codable
        //
        // `embedding` is 256 Floats. Encoding it as a JSON array would cost ~6 KB per speaker and
        // re-run Float→ASCII conversion on every save of every session — the exact problem that
        // pushed waveform samples out into sidecar files (see the note further down this file).
        // It is therefore stored as base64 of the raw little-endian Float32 buffer: ~1.4 KB per
        // speaker, and no number formatting on the hot save path.

        private enum CodingKeys: String, CodingKey {
            case label, name, channel, sampleStart, sampleEnd
            case embedding, voiceID, wasAutoMatched, spokenSeconds
        }

        init(
            label: String,
            name: String? = nil,
            channel: Channel,
            sampleStart: TimeInterval,
            sampleEnd: TimeInterval,
            embedding: [Float]? = nil,
            voiceID: UUID? = nil,
            wasAutoMatched: Bool? = nil,
            spokenSeconds: TimeInterval? = nil
        ) {
            self.label = label
            self.name = name
            self.channel = channel
            self.sampleStart = sampleStart
            self.sampleEnd = sampleEnd
            self.embedding = embedding
            self.voiceID = voiceID
            self.wasAutoMatched = wasAutoMatched
            self.spokenSeconds = spokenSeconds
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decode(String.self, forKey: .label)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            channel = try c.decode(Channel.self, forKey: .channel)
            sampleStart = try c.decode(TimeInterval.self, forKey: .sampleStart)
            sampleEnd = try c.decode(TimeInterval.self, forKey: .sampleEnd)
            voiceID = try c.decodeIfPresent(UUID.self, forKey: .voiceID)
            wasAutoMatched = try c.decodeIfPresent(Bool.self, forKey: .wasAutoMatched)
            spokenSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .spokenSeconds)
            embedding = try c.decodeIfPresent(String.self, forKey: .embedding)
                .flatMap(Self.decodeEmbedding)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(label, forKey: .label)
            try c.encodeIfPresent(name, forKey: .name)
            try c.encode(channel, forKey: .channel)
            try c.encode(sampleStart, forKey: .sampleStart)
            try c.encode(sampleEnd, forKey: .sampleEnd)
            try c.encodeIfPresent(voiceID, forKey: .voiceID)
            try c.encodeIfPresent(wasAutoMatched, forKey: .wasAutoMatched)
            try c.encodeIfPresent(spokenSeconds, forKey: .spokenSeconds)
            try c.encodeIfPresent(embedding.map(Self.encodeEmbedding), forKey: .embedding)
        }

        private static func encodeEmbedding(_ values: [Float]) -> String {
            var littleEndian = values.map { $0.bitPattern.littleEndian }
            return Data(bytes: &littleEndian, count: littleEndian.count * 4).base64EncodedString()
        }

        private static func decodeEmbedding(_ encoded: String) -> [Float]? {
            guard let data = Data(base64Encoded: encoded), data.count % 4 == 0, !data.isEmpty
            else { return nil }
            return stride(from: 0, to: data.count, by: 4).map { offset in
                let bits = data[offset..<offset + 4].reduce(UInt32(0)) { partial, byte in
                    (partial >> 8) | (UInt32(byte) << 24)
                }
                return Float(bitPattern: bits)
            }
        }
    }

    struct CachedSpeechSegment: Codable, Equatable {
        var startTime: TimeInterval
        var endTime: TimeInterval
    }

    enum Channel: String, Codable, CaseIterable {
        case microphone
        case system
    }

    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var languageCode: String
    var status: Status
    var micFileName: String?
    var systemFileName: String?
    var transcript: Transcript?
    var lastErrorMessage: String?
    var meetingMinutesFileName: String?
    var liveTranscriptFileName: String?
    var duration: TimeInterval?
    var projectID: UUID?
    /// True when the user filed the meeting to the General workspace instead of a project
    /// (projectID stays nil). Counts as an assignment for MeetingProcessingRule. Optional, so
    /// existing sessions decode unchanged.
    var assignedToGeneral: Bool?
    /// Relative meeting folder inside the project's export folder ("2026-07-11/Weekly Sync").
    /// Set on first export so later exports (and title renames) target the same folder.
    var exportFolderName: String?
    /// Time offset in seconds between microphone and system audio recording starts.
    /// Positive means system audio started after microphone.
    var systemAudioOffsetSeconds: TimeInterval?
    
    // Audio cropping
    var cropStartTime: TimeInterval?
    var cropEndTime: TimeInterval?
    var originalMicFileName: String?  // Backup of original before cropping
    var originalSystemFileName: String?  // Backup of original before cropping
    
    // Waveform data (cached for performance)
    var waveformSamples: [Float]?  // Normalized amplitude samples (0.0 to 1.0)
    var waveformDuration: TimeInterval?  // Duration of the waveform
    var waveformSpeechSegments: [CachedSpeechSegment]?  // Speech detection segments
    var waveformChannel: String?  // Which channel was used for waveform ("microphone" or "system")

    // MARK: - Calendar Integration Fields
    // All optional for Codable backward compatibility — legacy JSON without these keys decodes cleanly.
    var calendarEventID: String?
    var calendarEventTitle: String?
    var calendarAttendees: [String]?
    var calendarScheduledStart: Date?
    var calendarScheduledEnd: Date?
    var calendarNotes: String?

    /// Speakers found by diarization, each with a short sample range for the naming UI.
    /// Nil when the recording was never diarized. Optional, so existing sessions decode unchanged.
    var speakerProfiles: [SpeakerProfile]?

    /// True once the user dismissed this meeting from the inbox without processing it.
    /// Optional, so existing sessions decode unchanged.
    var inboxDismissed: Bool?

    /// True when the user ticked "Keep audio": the audio survives AudioRetentionPolicy's
    /// 14-day purge. Optional, so existing sessions decode unchanged (nil = not kept).
    var keepAudio: Bool?

    /// What kind of capture this is. Nil means a meeting, so existing sessions decode unchanged.
    var kind: Kind?

    enum Kind: String, Codable {
        case meeting
        /// Started with a double tap of the dictation key (not a meeting): its own pill flow, and
        /// mirrored into the project workspace under recordings/ once it has a transcript.
        case quickRecording
    }

    var isQuickRecording: Bool { kind == .quickRecording }

    /// In a Shared Project: whether this meeting or recording goes to the other members (asked on
    /// the saved card). Nil = not decided, which counts as private. Optional, so existing sessions
    /// decode unchanged; ignored in Private projects.
    var publication: MeetingPublication?

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        languageCode: String,
        status: Status = .idle,
        micFileName: String? = nil,
        systemFileName: String? = nil,
        transcript: Transcript? = nil,
        lastErrorMessage: String? = nil,
        meetingMinutesFileName: String? = nil,
        liveTranscriptFileName: String? = nil,
        duration: TimeInterval? = nil,
        projectID: UUID? = nil,
        systemAudioOffsetSeconds: TimeInterval? = nil,
        cropStartTime: TimeInterval? = nil,
        cropEndTime: TimeInterval? = nil,
        originalMicFileName: String? = nil,
        originalSystemFileName: String? = nil,
        waveformSamples: [Float]? = nil,
        waveformDuration: TimeInterval? = nil,
        waveformSpeechSegments: [CachedSpeechSegment]? = nil,
        waveformChannel: String? = nil,
        calendarEventID: String? = nil,
        calendarEventTitle: String? = nil,
        calendarAttendees: [String]? = nil,
        calendarScheduledStart: Date? = nil,
        calendarScheduledEnd: Date? = nil,
        calendarNotes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.languageCode = languageCode
        self.status = status
        self.micFileName = micFileName
        self.systemFileName = systemFileName
        self.transcript = transcript
        self.lastErrorMessage = lastErrorMessage
        self.meetingMinutesFileName = meetingMinutesFileName
        self.liveTranscriptFileName = liveTranscriptFileName
        self.duration = duration
        self.projectID = projectID
        self.systemAudioOffsetSeconds = systemAudioOffsetSeconds
        self.cropStartTime = cropStartTime
        self.cropEndTime = cropEndTime
        self.originalMicFileName = originalMicFileName
        self.originalSystemFileName = originalSystemFileName
        self.waveformSamples = waveformSamples
        self.waveformDuration = waveformDuration
        self.waveformSpeechSegments = waveformSpeechSegments
        self.waveformChannel = waveformChannel
        self.calendarEventID = calendarEventID
        self.calendarEventTitle = calendarEventTitle
        self.calendarAttendees = calendarAttendees
        self.calendarScheduledStart = calendarScheduledStart
        self.calendarScheduledEnd = calendarScheduledEnd
        self.calendarNotes = calendarNotes
    }

    var isActive: Bool {
        status.isActive
    }

    func fileName(for channel: Channel) -> String? {
        switch channel {
        case .microphone:
            return micFileName
        case .system:
            return systemFileName
        }
    }

    func fileURL(for channel: Channel, baseURL: URL) -> URL? {
        guard let fileName = fileName(for: channel) else {
            return nil
        }
        return baseURL.appendingPathComponent(fileName)
    }

    func meetingMinutesURL(baseURL: URL) -> URL? {
        guard let fileName = meetingMinutesFileName else {
            return nil
        }
        return baseURL.appendingPathComponent(fileName)
    }

    // MARK: - Codable
    //
    // Waveform data (`waveformSamples`, `waveformDuration`, `waveformSpeechSegments`,
    // `waveformChannel`) is intentionally OMITTED from encoding. Persisting hundreds of
    // Float samples per session through JSONEncoder dominated startup CPU on installs
    // with many recordings (Float→ASCII conversion ran for every sample on every save).
    // Waveforms now live in per-session binary sidecar files via `WaveformStore`.
    //
    // Decoding still accepts these keys so legacy `sessions.json` files load cleanly
    // and `AppViewModel.migrateWaveformsToSidecar()` can move them to sidecar files
    // on first launch.

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, languageCode, status
        case micFileName, systemFileName, transcript, lastErrorMessage
        case meetingMinutesFileName, liveTranscriptFileName, duration, projectID, assignedToGeneral
        case exportFolderName
        case systemAudioOffsetSeconds
        case cropStartTime, cropEndTime, originalMicFileName, originalSystemFileName
        case waveformSamples, waveformDuration, waveformSpeechSegments, waveformChannel
        case calendarEventID, calendarEventTitle, calendarAttendees
        case calendarScheduledStart, calendarScheduledEnd, calendarNotes
        case speakerProfiles
        case inboxDismissed
        case keepAudio
        case kind
        case publication
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(languageCode, forKey: .languageCode)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(micFileName, forKey: .micFileName)
        try c.encodeIfPresent(systemFileName, forKey: .systemFileName)
        try c.encodeIfPresent(transcript, forKey: .transcript)
        try c.encodeIfPresent(lastErrorMessage, forKey: .lastErrorMessage)
        try c.encodeIfPresent(meetingMinutesFileName, forKey: .meetingMinutesFileName)
        try c.encodeIfPresent(liveTranscriptFileName, forKey: .liveTranscriptFileName)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(projectID, forKey: .projectID)
        try c.encodeIfPresent(assignedToGeneral, forKey: .assignedToGeneral)
        try c.encodeIfPresent(exportFolderName, forKey: .exportFolderName)
        try c.encodeIfPresent(systemAudioOffsetSeconds, forKey: .systemAudioOffsetSeconds)
        try c.encodeIfPresent(cropStartTime, forKey: .cropStartTime)
        try c.encodeIfPresent(cropEndTime, forKey: .cropEndTime)
        try c.encodeIfPresent(originalMicFileName, forKey: .originalMicFileName)
        try c.encodeIfPresent(originalSystemFileName, forKey: .originalSystemFileName)
        // Waveform keys deliberately omitted — see note above.
        try c.encodeIfPresent(calendarEventID, forKey: .calendarEventID)
        try c.encodeIfPresent(calendarEventTitle, forKey: .calendarEventTitle)
        try c.encodeIfPresent(calendarAttendees, forKey: .calendarAttendees)
        try c.encodeIfPresent(calendarScheduledStart, forKey: .calendarScheduledStart)
        try c.encodeIfPresent(calendarScheduledEnd, forKey: .calendarScheduledEnd)
        try c.encodeIfPresent(calendarNotes, forKey: .calendarNotes)
        try c.encodeIfPresent(speakerProfiles, forKey: .speakerProfiles)
        try c.encodeIfPresent(inboxDismissed, forKey: .inboxDismissed)
        try c.encodeIfPresent(keepAudio, forKey: .keepAudio)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(publication, forKey: .publication)
    }
}

// MARK: - Transcription Result

extension RecordingSession {
    /// Copies what a transcription run produced from `run` (the copy the run started with and
    /// filled in) onto this session as it is now. A transcription takes minutes, and meanwhile
    /// the user keeps working on the meeting: picks a project or General, renames it, ticks
    /// "Keep audio", skips it in the inbox. Writing the run's copy back whole would undo all of
    /// that (2026-10-13: a project picked during transcription was lost), so only the fields
    /// transcription owns are taken over. A run that sets another field must add it here.
    mutating func takeTranscriptionResult(from run: RecordingSession) {
        status = run.status
        lastErrorMessage = run.lastErrorMessage
        languageCode = run.languageCode
        transcript = run.transcript
        speakerProfiles = run.speakerProfiles
    }

    /// Takes over the audio file names a post-recording conversion (.caf to .m4a) produced, for
    /// the same reason as `takeTranscriptionResult(from:)`.
    mutating func takeConvertedAudio(from run: RecordingSession) {
        micFileName = run.micFileName
        systemFileName = run.systemFileName
    }
}

// MARK: - Calendar Session Factory

/// Free function visible at module scope so ModelTests can call it without an AppViewModel instance.
/// Creates a RecordingSession pre-filled with CalendarEvent data.
func createSession(from event: CalendarEvent) -> RecordingSession {
    var session = RecordingSession(
        title: event.title,
        languageCode: "en-US"
    )
    session.calendarEventID = event.id
    session.calendarEventTitle = event.title
    session.calendarAttendees = event.attendees
    session.calendarScheduledStart = event.startDate
    session.calendarScheduledEnd = event.endDate
    session.calendarNotes = event.notes
    return session
}
