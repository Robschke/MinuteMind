import Foundation
import PDFKit
import AppKit

/// Service for parsing content from various file formats
struct FileParserService {
    
    enum ParserError: Error, LocalizedError {
        case unsupportedFileType
        case fileNotFound
        case parsingFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .unsupportedFileType:
                return "Unsupported file type"
            case .fileNotFound:
                return "File not found"
            case .parsingFailed(let message):
                return "Failed to parse file: \(message)"
            }
        }
    }
    
    /// Extract text content from a file
    func extractText(from url: URL) async throws -> String {
        let fileExtension = url.pathExtension.lowercased()
        
        switch fileExtension {
        case "pdf":
            return try extractFromPDF(url)
        case "doc", "docx":
            return try await extractFromWord(url)
        case "ppt", "pptx":
            return try await extractFromPowerPoint(url)
        default:
            throw ParserError.unsupportedFileType
        }
    }
    
    // MARK: - PDF Parsing
    
    private func extractFromPDF(_ url: URL) throws -> String {
        guard let pdfDocument = PDFDocument(url: url) else {
            throw ParserError.parsingFailed("Could not open PDF")
        }
        
        var text = ""
        for pageIndex in 0..<pdfDocument.pageCount {
            if let page = pdfDocument.page(at: pageIndex),
               let pageText = page.string {
                text += pageText + "\n\n"
            }
        }
        
        guard !text.isEmpty else {
            throw ParserError.parsingFailed("No text content found in PDF")
        }
        
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Word Document Parsing
    
    private func extractFromWord(_ url: URL) async throws -> String {
        // For .docx files, we can try to extract from the XML
        if url.pathExtension.lowercased() == "docx" {
            return try extractFromDocx(url)
        } else {
            // For .doc files, we'll need to use a different approach
            // For now, return an error or use TextEdit to convert
            throw ParserError.parsingFailed("Legacy .doc format not yet supported. Please use .docx")
        }
    }
    
    private func extractFromDocx(_ url: URL) throws -> String {
        // .docx is a ZIP archive containing XML files
        // We'll extract document.xml from word/ directory
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // Unzip the docx file
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", url.path, "-d", tempDir.path]
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw ParserError.parsingFailed("Failed to extract docx archive")
        }
        
        // Read the document.xml file
        let documentPath = tempDir.appendingPathComponent("word/document.xml")
        guard let xmlData = try? Data(contentsOf: documentPath),
              let xmlString = String(data: xmlData, encoding: .utf8) else {
            throw ParserError.parsingFailed("Could not read document.xml")
        }
        
        // Extract text from XML (simple approach - removes all tags)
        let text = extractTextFromXML(xmlString)
        
        guard !text.isEmpty else {
            throw ParserError.parsingFailed("No text content found in Word document")
        }
        
        return text
    }
    
    // MARK: - PowerPoint Parsing
    
    private func extractFromPowerPoint(_ url: URL) async throws -> String {
        // Similar to Word, .pptx is a ZIP archive
        if url.pathExtension.lowercased() == "pptx" {
            return try extractFromPptx(url)
        } else {
            throw ParserError.parsingFailed("Legacy .ppt format not yet supported. Please use .pptx")
        }
    }
    
    private func extractFromPptx(_ url: URL) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // Unzip the pptx file
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", url.path, "-d", tempDir.path]
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw ParserError.parsingFailed("Failed to extract pptx archive")
        }
        
        // Read all slide XML files
        let slidesDir = tempDir.appendingPathComponent("ppt/slides")
        var allText = ""
        
        if let slideFiles = try? FileManager.default.contentsOfDirectory(at: slidesDir, includingPropertiesForKeys: nil) {
            let sortedSlides = slideFiles.filter { $0.pathExtension == "xml" && $0.lastPathComponent.hasPrefix("slide") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            
            for (index, slideFile) in sortedSlides.enumerated() {
                if let xmlData = try? Data(contentsOf: slideFile),
                   let xmlString = String(data: xmlData, encoding: .utf8) {
                    let slideText = extractTextFromXML(xmlString)
                    if !slideText.isEmpty {
                        allText += "--- Slide \(index + 1) ---\n\(slideText)\n\n"
                    }
                }
            }
        }
        
        guard !allText.isEmpty else {
            throw ParserError.parsingFailed("No text content found in PowerPoint")
        }
        
        return allText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Helper Methods
    
    private func extractTextFromXML(_ xmlString: String) -> String {
        // Simple XML text extraction - finds content between <w:t> or <a:t> tags
        var text = ""
        let patterns = ["<w:t[^>]*>([^<]+)</w:t>", "<a:t[^>]*>([^<]+)</a:t>"]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let nsString = xmlString as NSString
                let matches = regex.matches(in: xmlString, range: NSRange(location: 0, length: nsString.length))
                
                for match in matches {
                    if match.numberOfRanges > 1 {
                        let matchedText = nsString.substring(with: match.range(at: 1))
                        text += matchedText + " "
                    }
                }
            }
        }
        
        // Clean up the text
        return text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
