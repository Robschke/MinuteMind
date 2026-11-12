import Foundation

/// Persists projects and tasks to JSON files.
/// Provides debounced save variants that coalesce rapid mutations into a single disk write.
final class ProjectStore {
    let baseDirectory: URL
    private let fileManager: FileManager

    private var projectsFileURL: URL {
        baseDirectory.appendingPathComponent("projects.json")
    }

    private var tasksFileURL: URL {
        baseDirectory.appendingPathComponent("tasks.json")
    }

    private var epicsFileURL: URL {
        baseDirectory.appendingPathComponent("epics.json")
    }

    // MARK: - Debounced save infrastructure

    private let saveQueue = DispatchQueue(label: "ProjectStore.save", qos: .utility)
    private var pendingTasksSave: DispatchWorkItem?
    private var pendingProjectsSave: DispatchWorkItem?
    private var pendingEpicsSave: DispatchWorkItem?

    init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }
    
    func ensureDirectories() throws {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }
    }
    
    // MARK: - Projects
    
    func loadProjects() throws -> [Project] {
        guard fileManager.fileExists(atPath: projectsFileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: projectsFileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Project].self, from: data)
    }
    
    func saveProjects(_ projects: [Project]) throws {
        try ensureDirectories()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(projects)
        try data.write(to: projectsFileURL, options: .atomic)
    }

    /// Debounced variant — coalesces rapid mutations into one disk write after `delay` seconds.
    func debouncedSaveProjects(_ projects: [Project], delay: TimeInterval = 0.3) {
        pendingProjectsSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            try? self?.saveProjects(projects)
        }
        pendingProjectsSave = work
        saveQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }
    
    // MARK: - Tasks
    
    func loadTasks() throws -> [ProjectTask] {
        guard fileManager.fileExists(atPath: tasksFileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: tasksFileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ProjectTask].self, from: data)
    }
    
    func saveTasks(_ tasks: [ProjectTask]) throws {
        try ensureDirectories()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(tasks)
        try data.write(to: tasksFileURL, options: .atomic)
    }

    /// Debounced variant — coalesces rapid mutations into one disk write after `delay` seconds.
    func debouncedSaveTasks(_ tasks: [ProjectTask], delay: TimeInterval = 0.3) {
        pendingTasksSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            try? self?.saveTasks(tasks)
        }
        pendingTasksSave = work
        saveQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }
    
    /// Load tasks for a specific project
    func loadTasks(for projectID: UUID) throws -> [ProjectTask] {
        let allTasks = try loadTasks()
        return allTasks.filter { $0.projectID == projectID }
    }

    // MARK: - Epics

    func loadEpics() throws -> [Epic] {
        guard fileManager.fileExists(atPath: epicsFileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: epicsFileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Epic].self, from: data)
    }

    func saveEpics(_ epics: [Epic]) throws {
        try ensureDirectories()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(epics)
        try data.write(to: epicsFileURL, options: .atomic)
    }

    /// Debounced variant — coalesces rapid mutations into one disk write after `delay` seconds.
    func debouncedSaveEpics(_ epics: [Epic], delay: TimeInterval = 0.3) {
        pendingEpicsSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            try? self?.saveEpics(epics)
        }
        pendingEpicsSave = work
        saveQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Execute any pending debounced saves immediately (call before app termination).
    func flushPendingSaves() {
        pendingTasksSave?.perform()
        pendingTasksSave = nil
        pendingProjectsSave?.perform()
        pendingProjectsSave = nil
        pendingEpicsSave?.perform()
        pendingEpicsSave = nil
    }
}
