import Foundation
import Testing
@testable import MinuteMindApp

// MARK: - Test Models (mirroring CalendarBlockerService types)

struct TestBlockerResponse: Codable {
    let suggestions: [TestSuggestedBlock]
    let explanation: String
}

struct TestSuggestedBlock: Codable {
    let startTime: String
    let endTime: String
    let reasoning: String
}

@Suite("CalendarBlockerService Tests")
struct CalendarBlockerServiceTests {
    
    // MARK: - Response Parsing Tests
    
    @Test("Parse valid AI response with ISO8601 dates")
    func testParseValidResponse() throws {
        let jsonResponse = """
        {
            "suggestions": [
                {
                    "startTime": "2025-12-19T09:00:00Z",
                    "endTime": "2025-12-19T10:30:00Z",
                    "reasoning": "Morning slot with no conflicts"
                },
                {
                    "startTime": "2025-12-19T14:00:00Z",
                    "endTime": "2025-12-19T15:00:00Z",
                    "reasoning": "Afternoon focus time"
                }
            ],
            "explanation": "Split into two focused sessions"
        }
        """
        
        let jsonData = jsonResponse.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TestBlockerResponse.self, from: jsonData)
        
        #expect(decoded.suggestions.count == 2)
        #expect(decoded.explanation == "Split into two focused sessions")
        
        // Test date parsing
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        
        let firstStart = isoFormatter.date(from: decoded.suggestions[0].startTime)
        let firstEnd = isoFormatter.date(from: decoded.suggestions[0].endTime)
        
        #expect(firstStart != nil, "Start time should parse")
        #expect(firstEnd != nil, "End time should parse")
    }
    
    @Test("Parse AI response with various ISO8601 formats")
    func testParseVariousDateFormats() throws {
        // AI might return dates in different formats
        let formats = [
            "2025-12-19T09:00:00Z",           // Standard with Z
            "2025-12-19T09:00:00+00:00",      // With timezone offset
            "2025-12-19T09:00:00.000Z",       // With milliseconds
            "2025-12-19T14:00:00-05:00",      // With negative offset
        ]
        
        for format in formats {
            let date = parseDate(format)
            #expect(date != nil, "Should parse: \(format)")
        }
    }
    
    @Test("Parse AI response with local time format")
    func testParseLocalTimeFormat() throws {
        // AI might return local times without timezone
        let localTimeString = "2025-12-19T09:00:00"
        
        // Standard ISO8601 won't parse this
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let result1 = isoFormatter.date(from: localTimeString)
        
        // Our parseDate function should handle it
        let result2 = parseDate(localTimeString)
        
        #expect(result1 == nil, "ISO8601 formatter won't parse local time")
        #expect(result2 != nil, "parseDate should parse local time")
    }
    
    @Test("Empty suggestions array")
    func testEmptySuggestions() throws {
        let jsonResponse = """
        {
            "suggestions": [],
            "explanation": "No available time slots found"
        }
        """
        
        let jsonData = jsonResponse.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TestBlockerResponse.self, from: jsonData)
        
        #expect(decoded.suggestions.isEmpty)
        #expect(!decoded.explanation.isEmpty)
    }
    
    // MARK: - Duration Tests
    
    @Test("Duration calculation from dates")
    func testDurationCalculation() {
        let start = Date()
        let end = start.addingTimeInterval(90 * 60) // 90 minutes
        
        let durationMinutes = Int(end.timeIntervalSince(start) / 60)
        
        #expect(durationMinutes == 90)
    }
    
    // MARK: - Helper
    
    /// Parse various ISO8601 date formats that AI might return
    private func parseDate(_ string: String) -> Date? {
        // Try standard ISO8601 with timezone
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: string) {
            return date
        }
        
        // Try with fractional seconds
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: string) {
            return date
        }
        
        // Try local time format (no timezone)
        let localFormatter = DateFormatter()
        localFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        localFormatter.timeZone = TimeZone.current
        if let date = localFormatter.date(from: string) {
            return date
        }
        
        // Try with just date and time, no T separator
        localFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = localFormatter.date(from: string) {
            return date
        }
        
        return nil
    }
}
