import Foundation

/// Represents an item in a project workspace (file or folder)
enum WorkspaceItem: Identifiable, Codable, Equatable {
    case folder(WorkspaceFolder)
    case file(WorkspaceFile)
    
    var id: UUID {
        switch self {
        case .folder(let folder): return folder.id
        case .file(let file): return file.id
        }
    }
    
    var name: String {
        switch self {
        case .folder(let folder): return folder.name
        case .file(let file): return file.name
        }
    }
    
    var createdAt: Date {
        switch self {
        case .folder(let folder): return folder.createdAt
        case .file(let file): return file.createdAt
        }
    }
    
    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }
}

/// A folder in the workspace
struct WorkspaceFolder: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var parentID: UUID? // nil for root-level folders
    var children: [WorkspaceItem]
    var createdAt: Date
    var modifiedAt: Date
    
    init(
        id: UUID = UUID(),
        name: String,
        parentID: UUID? = nil,
        children: [WorkspaceItem] = [],
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.children = children
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
    
    /// Get all descendant items (recursive)
    func allDescendants() -> [WorkspaceItem] {
        var items: [WorkspaceItem] = []
        for child in children {
            items.append(child)
            if case .folder(let folder) = child {
                items.append(contentsOf: folder.allDescendants())
            }
        }
        return items
    }
}

/// A file in the workspace
struct WorkspaceFile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var parentID: UUID? // nil for root-level files
    var fileURL: URL? // Reference to actual file on disk
    var fileSize: Int64? // Size in bytes
    var fileType: String // UTI or file extension
    var createdAt: Date
    var modifiedAt: Date
    
    init(
        id: UUID = UUID(),
        name: String,
        parentID: UUID? = nil,
        fileURL: URL? = nil,
        fileSize: Int64? = nil,
        fileType: String = "",
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.fileURL = fileURL
        self.fileSize = fileSize
        self.fileType = fileType
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
    
    /// Get human-readable file size
    var formattedSize: String {
        guard let size = fileSize else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
    
    /// Get file extension
    var fileExtension: String {
        (name as NSString).pathExtension
    }
    
    /// Get icon name for file type
    var iconName: String {
        let ext = fileExtension.lowercased()
        switch ext {
        case "pdf": return "doc.fill"
        case "txt", "md": return "doc.text.fill"
        case "jpg", "jpeg", "png", "gif", "heic": return "photo.fill"
        case "mp3", "m4a", "wav": return "waveform"
        case "mp4", "mov": return "video.fill"
        case "zip", "tar", "gz": return "doc.zipper"
        case "swift", "py", "js", "ts", "java": return "chevron.left.forwardslash.chevron.right"
        case "json", "xml", "yaml": return "doc.badge.gearshape"
        default: return "doc"
        }
    }
}

/// Workspace for a project containing folders and files
struct ProjectWorkspace: Codable, Equatable {
    let projectID: UUID
    var rootItems: [WorkspaceItem]
    var updatedAt: Date
    
    init(projectID: UUID, rootItems: [WorkspaceItem] = [], updatedAt: Date = Date()) {
        self.projectID = projectID
        self.rootItems = rootItems
        self.updatedAt = updatedAt
    }
    
    /// Search for items by name
    func search(query: String) -> [WorkspaceItem] {
        let lowercaseQuery = query.lowercased()
        var results: [WorkspaceItem] = []
        
        func searchIn(items: [WorkspaceItem]) {
            for item in items {
                if item.name.lowercased().contains(lowercaseQuery) {
                    results.append(item)
                }
                if case .folder(let folder) = item {
                    searchIn(items: folder.children)
                }
            }
        }
        
        searchIn(items: rootItems)
        return results
    }
    
    /// Get all items flattened
    func allItems() -> [WorkspaceItem] {
        var items: [WorkspaceItem] = []
        func collectItems(_ collection: [WorkspaceItem]) {
            for item in collection {
                items.append(item)
                if case .folder(let folder) = item {
                    collectItems(folder.children)
                }
            }
        }
        collectItems(rootItems)
        return items
    }
}
