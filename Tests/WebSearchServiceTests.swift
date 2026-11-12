import Foundation
import Testing

@testable import MinuteMindApp

struct WebSearchServiceTests {
    
    @Test func webSearchReturnsResults() async throws {
        // This is an integration test that requires internet connectivity
        // Skip in CI/offline environments by checking environment variable
        guard ProcessInfo.processInfo.environment["SKIP_NETWORK_TESTS"] == nil else {
            return
        }
        
        let response = try await WebSearchService.search(query: "Swift programming language", resultCount: 3)
        
        #expect(response.results.count > 0)
        #expect(response.results.count <= 3)
        #expect(response.query == "Swift programming language")
        
        // Verify result structure
        for result in response.results {
            #expect(!result.title.isEmpty)
            #expect(!result.url.isEmpty)
            #expect(result.url.hasPrefix("http"))
            #expect(!result.snippet.isEmpty)
        }
    }
    
    @Test func fetchWebpageReturnsContent() async throws {
        // This is an integration test that requires internet connectivity
        guard ProcessInfo.processInfo.environment["SKIP_NETWORK_TESTS"] == nil else {
            return
        }
        
        // Use a stable, simple webpage
        let url = URL(string: "https://www.example.com")!
        let content = try await WebSearchService.fetchWebpage(url: url, maxLength: 5000)
        
        #expect(!content.isEmpty)
        #expect(content.count <= 5000)
        // Content should be cleaned (no HTML tags)
        #expect(!content.contains("<html>"))
        #expect(!content.contains("<script>"))
    }
    
    @Test func fetchWebpageTruncatesLongContent() async throws {
        guard ProcessInfo.processInfo.environment["SKIP_NETWORK_TESTS"] == nil else {
            return
        }
        
        let url = URL(string: "https://www.example.com")!
        let content = try await WebSearchService.fetchWebpage(url: url, maxLength: 500)
        
        #expect(content.count <= 550) // Allow for truncation message
        if content.count >= 500 {
            #expect(content.contains("Content truncated"))
        }
    }
}
