import Foundation

/// Service for web search and webpage fetching using public SearxNG instances
struct WebSearchService {
    
    // MARK: - Models
    
    struct SearchResult: Codable {
        let title: String
        let url: String
        let snippet: String
        
        init(title: String, url: String, snippet: String) {
            self.title = title
            self.url = url
            self.snippet = snippet
        }
    }
    
    struct SearchResponse: Codable {
        let results: [SearchResult]
        let query: String
        let source: String  // Which SearxNG instance was used
    }
    
    // MARK: - Errors
    
    enum SearchError: Error, LocalizedError {
        case allInstancesFailed
        case invalidURL
        case noResults
        case fetchFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .allInstancesFailed:
                return "All search instances failed. Please check your internet connection."
            case .invalidURL:
                return "Invalid URL provided"
            case .noResults:
                return "No search results found"
            case .fetchFailed(let msg):
                return "Failed to fetch webpage: \(msg)"
            }
        }
    }
    
    // MARK: - SearxNG Public Instances
    
    /// Public SearxNG instances (rotated for reliability)
    private static let searxInstances = [
        "https://searx.be",
        "https://search.bus-hit.me",
        "https://searx.ninja",
        "https://searx.tiekoetter.com",
        "https://searx.work"
    ]
    
    // MARK: - Web Search
    
    /// Search the web using public SearxNG instances with automatic fallback
    static func search(query: String, resultCount: Int = 5) async throws -> SearchResponse {
        var lastError: Error?
        
        // Try each instance until one succeeds
        for instance in searxInstances {
            do {
                let response = try await searchWithInstance(
                    instance: instance,
                    query: query,
                    resultCount: resultCount
                )
                return response
            } catch {
                lastError = error
                // Continue to next instance
                continue
            }
        }
        
        // All instances failed
        throw lastError ?? SearchError.allInstancesFailed
    }
    
    private static func searchWithInstance(
        instance: String,
        query: String,
        resultCount: Int
    ) async throws -> SearchResponse {
        // Build SearxNG API URL
        guard var urlComponents = URLComponents(string: "\(instance)/search") else {
            throw SearchError.invalidURL
        }
        
        urlComponents.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "categories", value: "general"),
            URLQueryItem(name: "language", value: "en")
        ]
        
        guard let url = urlComponents.url else {
            throw SearchError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10  // Shorter timeout for public instances
        request.setValue("MinuteMind/1.0", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SearchError.fetchFailed("Invalid response")
        }
        
        guard httpResponse.statusCode == 200 else {
            throw SearchError.fetchFailed("HTTP \(httpResponse.statusCode)")
        }
        
        // Parse SearxNG JSON response
        let searxResponse = try JSONDecoder().decode(SearxNGResponse.self, from: data)
        
        // Convert to our format
        let results = searxResponse.results.prefix(resultCount).map { result in
            SearchResult(
                title: result.title,
                url: result.url,
                snippet: result.content ?? "No description available"
            )
        }
        
        guard !results.isEmpty else {
            throw SearchError.noResults
        }
        
        return SearchResponse(
            results: Array(results),
            query: query,
            source: instance
        )
    }
    
    // MARK: - Webpage Fetching
    
    /// Fetch and extract main text content from a webpage
    static func fetchWebpage(url: URL, maxLength: Int = 8000) async throws -> String {
        // Ensure HTTPS for App Transport Security
        guard url.scheme == "https" else {
            throw SearchError.fetchFailed("URL must use HTTPS protocol. HTTP is not allowed by App Transport Security.")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("MinuteMind/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SearchError.fetchFailed("Invalid response")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw SearchError.fetchFailed("HTTP \(httpResponse.statusCode)")
        }
        
        // Decode HTML
        guard let html = String(data: data, encoding: .utf8) else {
            throw SearchError.fetchFailed("Could not decode HTML")
        }
        
        // Extract main content (remove HTML tags and clean up)
        let cleanedText = extractMainContent(from: html)
        
        // Truncate if needed
        if cleanedText.count > maxLength {
            let truncated = String(cleanedText.prefix(maxLength))
            return truncated + "\n\n[Content truncated at \(maxLength) characters]"
        }
        
        return cleanedText
    }
    
    // MARK: - HTML Content Extraction
    
    private static func extractMainContent(from html: String) -> String {
        var text = html
        
        // Remove script and style tags with their content
        text = text.replacingOccurrences(
            of: "<script[^>]*>[\\s\\S]*?</script>",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "<style[^>]*>[\\s\\S]*?</style>",
            with: "",
            options: .regularExpression
        )
        
        // Remove HTML comments
        text = text.replacingOccurrences(
            of: "<!--[\\s\\S]*?-->",
            with: "",
            options: .regularExpression
        )
        
        // Remove all HTML tags
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        
        // Decode HTML entities
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&apos;", with: "'")
        
        // Clean up whitespace
        text = text.replacingOccurrences(
            of: "[ \\t]+",
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
        
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - SearxNG Response Models

private struct SearxNGResponse: Codable {
    let results: [SearxNGResult]
}

private struct SearxNGResult: Codable {
    let title: String
    let url: String
    let content: String?
}
