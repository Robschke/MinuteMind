import SwiftUI
import UniformTypeIdentifiers

/// Finder-like workspace view for managing files and folders in a project
struct WorkspaceView: View {
    let project: Project
    @ObservedObject var workspaceStore: WorkspaceStore
    
    @State private var workspace: ProjectWorkspace
    @State private var currentFolder: UUID? = nil // nil = root
    @State private var searchQuery = ""
    @State private var selectedItem: UUID?
    @State private var showingNewFolderDialog = false
    @State private var newFolderName = ""
    @State private var itemToRename: UUID?
    @State private var renameText = ""
    @State private var showingDeleteConfirmation = false
    @State private var itemToDelete: UUID?
    @State private var errorMessage: String?
    
    init(project: Project, workspaceStore: WorkspaceStore) {
        self.project = project
        self.workspaceStore = workspaceStore
        self._workspace = State(initialValue: workspaceStore.getWorkspace(for: project.id))
    }
    
    private var currentItems: [WorkspaceItem] {
        if !searchQuery.isEmpty {
            return workspace.search(query: searchQuery)
        }
        
        if let folderID = currentFolder {
            // Find the folder and return its children
            return findFolder(id: folderID)?.children ?? []
        }
        
        return workspace.rootItems
    }
    
    private var breadcrumbs: [WorkspaceBreadcrumb] {
        let crumbs: [WorkspaceBreadcrumb] = [WorkspaceBreadcrumb(id: nil, name: "Root")]
        
        guard let folderID = currentFolder else { return crumbs }
        
        // Build breadcrumb trail
        func buildTrail(targetID: UUID, items: [WorkspaceItem], path: [WorkspaceBreadcrumb]) -> [WorkspaceBreadcrumb]? {
            for item in items {
                if case .folder(let folder) = item {
                    if folder.id == targetID {
                        return path + [WorkspaceBreadcrumb(id: folder.id, name: folder.name)]
                    }
                    if let result = buildTrail(targetID: targetID, items: folder.children, path: path + [WorkspaceBreadcrumb(id: folder.id, name: folder.name)]) {
                        return result
                    }
                }
            }
            return nil
        }
        
        if let trail = buildTrail(targetID: folderID, items: workspace.rootItems, path: crumbs) {
            return trail
        }
        
        return crumbs
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                // Back button
                Button(action: navigateUp) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(currentFolder != nil ? .blue : .gray)
                }
                .disabled(currentFolder == nil)
                .buttonStyle(.plain)
                
                // Breadcrumbs
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(breadcrumbs) { crumb in
                            Button(action: { currentFolder = crumb.id }) {
                                Text(crumb.name)
                                    .font(.subheadline)
                                    .foregroundColor(crumb.id == currentFolder ? .primary : .secondary)
                            }
                            .buttonStyle(.plain)
                            
                            if crumb.id != breadcrumbs.last?.id {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                
                Spacer()
                
                // Search
                TextField("Search workspace...", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                
                // Actions
                Menu {
                    Button(action: { showingNewFolderDialog = true }) {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    
                    Button(action: importFiles) {
                        Label("Import Files", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.blue)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .menuStyle(.borderlessButton)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // Content area
            if currentItems.isEmpty {
                emptyState
            } else {
                itemsList
            }
        }
        .alert("New Folder", isPresented: $showingNewFolderDialog) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) {
                newFolderName = ""
            }
            Button("Create") {
                createFolder()
            }
            .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .alert("Delete Item", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteSelectedItem()
            }
        } message: {
            if let item = findItem(id: itemToDelete) {
                Text("Are you sure you want to delete '\(item.name)'?")
            }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let error = errorMessage {
                Text(error)
            }
        }
        .onAppear {
            refreshWorkspace()
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text(searchQuery.isEmpty ? "No items" : "No results found")
                .font(.headline)
                .foregroundColor(.secondary)
            
            if searchQuery.isEmpty {
                Button("Create Folder") {
                    showingNewFolderDialog = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var itemsList: some View {
        List(currentItems, id: \.id, selection: $selectedItem) { item in
            itemRow(item)
                .contextMenu {
                    itemContextMenu(item)
                }
        }
        .listStyle(.inset)
    }
    
    @ViewBuilder
    private func itemRow(_ item: WorkspaceItem) -> some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: item.isFolder ? "folder.fill" : fileIcon(item))
                .foregroundColor(item.isFolder ? .blue : .secondary)
                .imageScale(.large)
                .frame(width: 24)
            
            // Name
            if itemToRename == item.id {
                TextField("Name", text: $renameText, onCommit: {
                    commitRename()
                })
                .textFieldStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 13))
                    
                    HStack(spacing: 8) {
                        Text(formattedDate(item.createdAt))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if case .file(let file) = item {
                            Text("•")
                                .foregroundColor(.secondary)
                                .font(.caption)
                            Text(file.formattedSize)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            
            Spacer()
            
            // Quick actions
            if selectedItem == item.id {
                HStack(spacing: 8) {
                    if item.isFolder {
                        Button(action: { openFolder(item.id) }) {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    } else if case .file(let file) = item, let url = file.fileURL {
                        Button(action: { openFile(url) }) {
                            Image(systemName: "eye.circle.fill")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if item.isFolder {
                openFolder(item.id)
            } else if case .file(let file) = item, let url = file.fileURL {
                openFile(url)
            }
        }
    }
    
    @ViewBuilder
    private func itemContextMenu(_ item: WorkspaceItem) -> some View {
        if item.isFolder {
            Button(action: { openFolder(item.id) }) {
                Label("Open", systemImage: "arrow.forward")
            }
        } else if case .file(let file) = item, let url = file.fileURL {
            Button(action: { openFile(url) }) {
                Label("Open", systemImage: "eye")
            }
            
            Button(action: { revealInFinder(url) }) {
                Label("Show in Finder", systemImage: "folder")
            }
        }
        
        Divider()
        
        Button(action: { startRename(item) }) {
            Label("Rename", systemImage: "pencil")
        }
        
        Divider()
        
        Button(role: .destructive, action: { confirmDelete(item.id) }) {
            Label("Delete", systemImage: "trash")
        }
    }
    
    // MARK: - Actions
    
    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        
        do {
            try workspaceStore.createFolder(name: name, parentID: currentFolder, in: project.id)
            refreshWorkspace()
            newFolderName = ""
        } catch {
            errorMessage = "Failed to create folder: \(error.localizedDescription)"
        }
    }
    
    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        
        panel.begin { response in
            guard response == .OK else { return }
            
            for url in panel.urls {
                do {
                    try workspaceStore.addFile(
                        name: url.lastPathComponent,
                        url: url,
                        parentID: currentFolder,
                        in: project.id
                    )
                } catch {
                    errorMessage = "Failed to import \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            
            refreshWorkspace()
        }
    }
    
    private func openFolder(_ id: UUID) {
        currentFolder = id
    }
    
    private func navigateUp() {
        guard let folderID = currentFolder else { return }
        
        // Find parent of current folder
        if let parent = findParentFolder(of: folderID) {
            currentFolder = parent.id
        } else {
            currentFolder = nil // Back to root
        }
    }
    
    private func openFile(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
    
    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }
    
    private func startRename(_ item: WorkspaceItem) {
        itemToRename = item.id
        renameText = item.name
    }
    
    private func commitRename() {
        guard let id = itemToRename else { return }
        let newName = renameText.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else {
            itemToRename = nil
            return
        }
        
        do {
            try workspaceStore.renameItem(id: id, newName: newName, in: project.id)
            refreshWorkspace()
        } catch {
            errorMessage = "Failed to rename: \(error.localizedDescription)"
        }
        
        itemToRename = nil
    }
    
    private func confirmDelete(_ id: UUID) {
        itemToDelete = id
        showingDeleteConfirmation = true
    }
    
    private func deleteSelectedItem() {
        guard let id = itemToDelete else { return }
        
        do {
            try workspaceStore.deleteItem(id: id, in: project.id)
            refreshWorkspace()
            if selectedItem == id {
                selectedItem = nil
            }
        } catch {
            errorMessage = "Failed to delete: \(error.localizedDescription)"
        }
        
        itemToDelete = nil
    }
    
    private func refreshWorkspace() {
        workspace = workspaceStore.getWorkspace(for: project.id)
    }
    
    // MARK: - Helpers
    
    private func findFolder(id: UUID) -> WorkspaceFolder? {
        func search(in items: [WorkspaceItem]) -> WorkspaceFolder? {
            for item in items {
                if case .folder(let folder) = item {
                    if folder.id == id {
                        return folder
                    }
                    if let found = search(in: folder.children) {
                        return found
                    }
                }
            }
            return nil
        }
        return search(in: workspace.rootItems)
    }
    
    private func findItem(id: UUID?) -> WorkspaceItem? {
        guard let id = id else { return nil }
        return workspace.allItems().first { $0.id == id }
    }
    
    private func findParentFolder(of id: UUID) -> WorkspaceFolder? {
        func search(in items: [WorkspaceItem]) -> WorkspaceFolder? {
            for item in items {
                if case .folder(let folder) = item {
                    // Check if this folder contains the target
                    if folder.children.contains(where: { $0.id == id }) {
                        return folder
                    }
                    // Recurse
                    if let found = search(in: folder.children) {
                        return found
                    }
                }
            }
            return nil
        }
        return search(in: workspace.rootItems)
    }
    
    private func fileIcon(_ item: WorkspaceItem) -> String {
        if case .file(let file) = item {
            return file.iconName
        }
        return "doc"
    }
    
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

struct WorkspaceBreadcrumb: Identifiable {
    let id: UUID?
    let name: String
}
