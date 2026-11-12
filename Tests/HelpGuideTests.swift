// Purpose: Tests for the MinuteMind user guide: topic ids and text are well-formed, lookup and
//          search find the right topic, and the text keeps the house style.
// Dependencies: Sources/App/Help/HelpGuide.swift, Sources/App/Help/HelpGuideContent.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("HelpGuide Tests")
struct HelpGuideTests {
    @Test("Topic ids are unique kebab-case and every topic has text")
    func topicsWellFormed() {
        let ids = HelpGuide.topics.map(\.id)
        #expect(Set(ids).count == ids.count)
        for topic in HelpGuide.topics {
            #expect(topic.id.range(of: "^[a-z]+(-[a-z]+)*$", options: .regularExpression) != nil, "bad id \(topic.id)")
            #expect(!topic.title.isEmpty && !topic.summary.isEmpty && !topic.icon.isEmpty)
            #expect(topic.body.count > 200, "\(topic.id) is too short")
        }
    }

    @Test("The guide uses no em or en dashes")
    func noDashes() {
        for topic in HelpGuide.topics {
            let text = topic.title + topic.summary + topic.body
            #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"), "dash in \(topic.id)")
        }
    }

    @Test("Topics are found by id and by title, ignoring case and spaces")
    func lookup() {
        #expect(HelpGuide.topic("inbox")?.id == "inbox")
        #expect(HelpGuide.topic("  Quick Dictation ")?.id == "quick-dictation")
        #expect(HelpGuide.topic("no-such-topic") == nil)
    }

    @Test("Search ranks the topic about a thing first and quotes matching passages")
    func search() {
        let dictation = HelpGuide.search("fn key dictation")
        #expect(dictation.first?.topic.id == "quick-dictation")
        #expect(dictation.first?.excerpts.isEmpty == false)

        #expect(HelpGuide.search("share project teammates publish").first?.topic.id == "shared-projects")
        #expect(HelpGuide.search("export folder").contains { $0.topic.id == "recording" })
        #expect(HelpGuide.search("a to").isEmpty, "words under three letters are ignored")
        #expect(HelpGuide.search("xylophone").isEmpty)
    }
}
