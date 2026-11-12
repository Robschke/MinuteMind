import Foundation

/// Represents a file attached to a knowledge entry
struct FileAttachment: Identifiable, Codable, Equatable {
    var id: UUID
    var fileName: String
    var filePath: String  // Relative path from knowledge base directory
    var fileType: FileType
    var fileSize: Int64
    var uploadedAt: Date
    
    enum FileType: String, Codable {
        case pdf = "pdf"
        case docx = "docx"
        case pptx = "pptx"
        case unknown = "unknown"
        
        init(from fileExtension: String) {
            switch fileExtension.lowercased() {
            case "pdf": self = .pdf
            case "doc", "docx": self = .docx
            case "ppt", "pptx": self = .pptx
            default: self = .unknown
            }
        }
        
        var icon: String {
            switch self {
            case .pdf: return "doc.fill"
            case .docx: return "doc.text.fill"
            case .pptx: return "square.stack.fill"
            case .unknown: return "doc"
            }
        }
    }
    
    init(
        id: UUID = UUID(),
        fileName: String,
        filePath: String,
        fileType: FileType,
        fileSize: Int64,
        uploadedAt: Date = Date()
    ) {
        self.id = id
        self.fileName = fileName
        self.filePath = filePath
        self.fileType = fileType
        self.fileSize = fileSize
        self.uploadedAt = uploadedAt
    }
}
