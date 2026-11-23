// Purpose: Tests for ChannelAlignment (offset between microphone and system channel) and
//          EchoSuppression (microphone runs that only repeat the loudspeaker).
// Dependencies: Sources/App/Transcription/ChannelAlignment.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("ChannelAlignment Tests")
struct ChannelAlignmentTests {

    private func words(_ text: String, from start: TimeInterval, step: TimeInterval = 0.4) -> [TimedWord] {
        text.split(separator: " ").enumerated().map { index, word in
            let wordStart = start + Double(index) * step
            return TimedWord(text: String(word), start: wordStart, end: wordStart + step - 0.1)
        }
    }

    // MARK: - Offset

    @Test("The offset is how much later the system channel started")
    func measuredOffset() {
        #expect(ChannelAlignment.offset(microphoneStart: 100.0, systemStart: 100.75) == 0.75)
    }

    @Test("Unknown or implausible starts give no offset")
    func implausibleOffset() {
        #expect(ChannelAlignment.offset(microphoneStart: nil, systemStart: 100) == nil)
        #expect(ChannelAlignment.offset(microphoneStart: 100, systemStart: nil) == nil)
        #expect(ChannelAlignment.offset(microphoneStart: 100, systemStart: 160) == nil)
    }

    @Test("Without a measurement the shorter system file gives the estimate")
    func estimatedOffset() {
        #expect(abs(ChannelAlignment.estimatedOffset(microphoneDuration: 1001.0, systemDuration: 998.8) - 2.2) < 0.001)
        // A longer system file, a huge difference or a missing length say nothing.
        #expect(ChannelAlignment.estimatedOffset(microphoneDuration: 600, systemDuration: 601) == 0)
        #expect(ChannelAlignment.estimatedOffset(microphoneDuration: 600, systemDuration: 300) == 0)
        #expect(ChannelAlignment.estimatedOffset(microphoneDuration: nil, systemDuration: 300) == 0)
    }

    // MARK: - Echo

    @Test("A microphone run repeating the system channel is dropped, misheard words included")
    func echoIsRemoved() {
        let system = words("Wann fahrt ihr denn morgen los? Wir treffen uns dann alle am Bahnhof um acht.", from: 10)
        let microphone = words("Wenn fahrt er denn morgen los, wir treffen uns dann alle am Bahnhof um acht", from: 10.3)
        let result = EchoSuppression.removingEcho(microphone: microphone, system: system)
        #expect(result.words.isEmpty)
        #expect(result.removed == microphone.count)
    }

    @Test("What the local speaker says while the others talk is kept")
    func ownSpeechIsKept() {
        let system = words("Dann machen wir das am Donnerstag mit dem ganzen Team zusammen", from: 10)
        let microphone = words("Ja das passt mir gut ich schicke die Einladung", from: 11)
        let result = EchoSuppression.removingEcho(microphone: microphone, system: system)
        #expect(result.words == microphone)
        #expect(result.removed == 0)
    }

    @Test("The same words much later are not echo")
    func laterRepetitionIsKept() {
        let system = words("wir brauchen zwei Leute für das Projekt", from: 10)
        let microphone = words("wir brauchen zwei Leute für das Projekt", from: 30)
        #expect(EchoSuppression.removingEcho(microphone: microphone, system: system).removed == 0)
    }

    @Test("Short agreement said by both sides is kept")
    func shortAgreementIsKept() {
        let system = words("Ja, genau.", from: 10)
        let microphone = words("Ja, genau.", from: 10.2)
        #expect(EchoSuppression.removingEcho(microphone: microphone, system: system).removed == 0)
    }

    @Test("Only the echoed run goes, the run after the pause stays")
    func onlyTheEchoedRunIsRemoved() {
        let system = words("also ich bin absolut dagegen das jetzt zu verschieben", from: 10)
        let echo = words("also ich bin absolut dagegen das jetzt zu verschieben", from: 10.2)
        let own = words("verstehe ich aber wer macht es dann", from: 20)
        let result = EchoSuppression.removingEcho(microphone: echo + own, system: system)
        #expect(result.words == own)
    }

    @Test("A remark made right after the echo, without a pause, is kept")
    func remarkAfterEchoIsKept() {
        let system = words("also ich bin absolut dagegen das jetzt zu verschieben", from: 10)
        let microphone = words("also ich bin absolut dagegen das jetzt zu verschieben warum denn eigentlich nicht wir haben doch genug Zeit", from: 10.2)
        let result = EchoSuppression.removingEcho(microphone: microphone, system: system)
        #expect(result.words.map(\.text).joined(separator: " ") == "warum denn eigentlich nicht wir haben doch genug Zeit")
    }

    @Test("Three-word runs need every word to match")
    func threeWordRuns() {
        #expect(EchoSuppression.isEcho(["nee", "ich", "glaube"], of: ["nee", "ich", "glaube", "die"]))
        #expect(!EchoSuppression.isEcho(["nee", "ich", "denke"], of: ["nee", "ich", "glaube", "die"]))
    }
}
