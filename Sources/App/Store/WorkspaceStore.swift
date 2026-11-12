import Foundation

/// Store for managing project workspaces
@MainActor
final class WorkspaceStore: ObservableObject {
    private let fileManager = FileManager.default
    private var workspacesDirectory: URL
    private var workspaces: [UUID: ProjectWorkspace] = [:]
    
    init(baseDirectory: URL? = nil) {
        // Default to Application Support directory
        let appSupport = baseDirectory ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        
        let appDir = appSupport.appendingPathComponent("MinuteMind", isDirectory: true)
        self.workspacesDirectory = appDir.appendingPathComponent("Workspaces", isDirectory: true)
        
        // Create directories if they don't exist
        try? fileManager.createDirectory(
            at: workspacesDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        
        loadAllWorkspaces()
    }
    
    // MARK: - Public API
    
    func getWorkspace(for projectID: UUID) -> ProjectWorkspace {
        if let existing = workspaces[projectID] {
            return existing
        }
        
        // Create new workspace
        let workspace = ProjectWorkspace(projectID: projectID)
        workspaces[projectID] = workspace
        saveWorkspace(workspace)
        return workspace
    }
    
    func createFolder(
        name: String,
        parentID: UUID? = nil,
        in projectID: UUID
    ) throws {
        var workspace = getWorkspace(for: projectID)
        let folder = WorkspaceFolder(name: name, parentID: parentID)
        
        if let parentID = parentID {
            // Add to parent folder
            workspace.rootItems = updateItems(workspace.rootItems) { item in
                if case .folder(var parent) = item, parent.id == parentID {
                    parent.children.append(.folder(folder))
                    parent.modifiedAt = Date()
                    return .folder(parent)
                }
                return item
            }
        } else {
            // Add to root
            workspace.rootItems.append(.folder(folder))
        }
        
        workspace.updatedAt = Date()
        workspaces[projectID] = workspace
        saveWorkspace(workspace)
    }
    
    func addFile(
        name: String,
        url: URL,
        parentID: UUID? = nil,
        in projectID: UUID
    ) throws {
        var workspace = getWorkspace(for: projectID)
        
        // Copy file to workspace directory
        let projectDir = workspacesDirectory.appendingPathComponent(projectID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
        
        let destinationURL = projectDir.appendingPathComponent(name)
        
        // If file exists, append number
        var finalURL = destinationURL
        var counter = 1
        while fileManager.fileExists(atPath: finalURL.path) {
            let nameWithoutExt = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            let newName = "\(nameWithoutExt) \(counter).\(ext)"
            finalURL = projectDir.appendingPathComponent(newName)
            counter += 1
        }
        
        try fileManager.copyItem(at: url, to: finalURL)
        
        // Get file attributes
        let attributes = try fileManager.attributesOfItem(atPath: finalURL.path)
        let fileSize = attributes[.size] as? Int64
        
        let file = WorkspaceFile(
            name: finalURL.lastPathComponent,
            parentID: parentID,
            fileURL: finalURL,
            fileSize: fileSize,
            fileType: finalURL.pathExtension
        )
        
        if let parentID = parentID {
            // Add to parent folder
            workspace.rootItems = updateItems(workspace.rootItems) { item in
                if case .folder(var parent) = item, parent.id == parentID {
                    parent.children.append(.file(file))
                    parent.modifiedAt = Date()
                    return .folder(parent)
                }
                return item
            }
        } else {
            // Add to root
            workspace.rootItems.append(.file(file))
        }
        
        workspace.updatedAt = Date()
        workspaces[projectID] = workspace
        saveWorkspace(workspace)
    }
    
    func deleteItem(id: UUID, in projectID: UUID) throws {
        var workspace = getWorkspace(for: projectID)
        
        // Find and delete the item (and its file if applicable)
        func deleteFromItems(_ items: [WorkspaceItem]) -> [WorkspaceItem] {
            items.compactMap { item in
                if item.id == id {
                    // Delete file from disk if it's a file
                    if case .file(let file) = item, let url = file.fileURL {
                        try? fileManager.removeItem(at: url)
                    }
                    return nil // Remove this item
                }
                
                if case .folder(var folder) = item {
                    folder.children = deleteFromItems(folder.children)
                    return .folder(folder)
                }
                
                return item
            }
        }
        
        workspace.rootItems = deleteFromItems(workspace.rootItems)
        workspace.updatedAt = Date()
        workspaces[projectID] = workspace
        saveWorkspace(workspace)
    }
    
    func renameItem(id: UUID, newName: String, in projectID: UUID) throws {
        var workspace = getWorkspace(for: projectID)
        
        workspace.rootItems = updateItems(workspace.rootItems) { item in
            if item.id == id {
                switch item {
                case .folder(var folder):
                    folder.name = newName
                    folder.modifiedAt = Date()
                    return .folder(folder)
                case .file(var file):
                    // Rename file on disk if it exists
                    if let oldURL = file.fileURL {
                        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newName)
                        try? fileManager.moveItem(at: oldURL, to: newURL)
                        file.fileURL = newURL
                    }
                    file.name = newName
                    file.modifiedAt = Date()
                    return .file(file)
                }
            }
            return item
        }
        
        workspace.updatedAt = Date()
        workspaces[projectID] = workspace
        saveWorkspace(workspace)
    }
    
    func moveItem(id: UUID, to newParentID: UUID?, in projectID: UUID) throws {
        var workspace = getWorkspace(for: projectID)
        
        // First, extract the item
        var itemToMove: WorkspaceItem?
        workspace.rootItems = removeItem(id, from: workspace.rootItems, extracted: &itemToMove)
        
        guard var item = itemToMove else { return }
        
        // Update parent ID
        switch item {
        case .folder(var folder):
            folder.parentID = newParentID
            item = .folder(folder)
        case .file(var file):
            file.parentID = newParentID
            item = .file(file)
        }
        
        // Add to new location
        if let newParentID = newParentID {
            workspace.rootItems = updateItems(workspace.rootItems) { currentItem in
                if case .folder(var parent) = currentItem, parent.id == newParentID {
                    parent.children.append(item)
                    parent.modifiedAt = Date()
                    return .folder(parent)
                }
                return currentItem
            }
        } else {
            workspace.rootItems.append(item)
        }
        
        workspace.updatedAt = Date()
        workspaces[projectID] = workspace
        saveWorkspace(workspace)
    }
    
    // MARK: - Private Helpers
    
    private func workspaceFileURL(for projectID: UUID) -> URL {
        workspacesDirectory.appendingPathComponent("\(projectID.uuidString).json")
    }
    
    private func loadAllWorkspaces() {
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: workspacesDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        
        for url in fileURLs where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let workspace = try? JSONDecoder().decode(ProjectWorkspace.self, from: data) {
                workspaces[workspace.projectID] = workspace
            }
        }
    }
    
    private func saveWorkspace(_ workspace: ProjectWorkspace) {
        let url = workspaceFileURL(for: workspace.projectID)
        if let data = try? JSONEncoder().encode(workspace) {
            try? data.write(to: url)
        }
    }
    
    private func updateItems(
        _ items: [WorkspaceItem],
        transform: (WorkspaceItem) -> WorkspaceItem
    ) -> [WorkspaceItem] {
        items.map { item in
            let transformed = transform(item)
            if case .folder(var folder) = transformed {
                folder.children = updateItems(folder.children, transform: transform)
                return .folder(folder)
            }
            return transformed
        }
    }
    
    private func removeItem(
        _ id: UUID,
        from items: [WorkspaceItem],
        extracted: inout WorkspaceItem?
    ) -> [WorkspaceItem] {
        items.compactMap { item in
            if item.id == id {
                extracted = item
                return nil
            }
            
            if case .folder(var folder) = item {
                folder.children = removeItem(id, from: folder.children, extracted: &extracted)
                return .folder(folder)
            }
            
            return item
        }
    }
}
