// Purpose: The data model of Shared Projects: a project whose workspace repo is shared with other
//          MinuteMind users through a git remote. Holds the per-meeting publish choice, the
//          project's sharing info, the manifest in the repo (.minutemind/project.json), the folder
//          layout (published vs. private/), the contributor's display name and the sync status.
// Dependencies: Foundation only.
// RBAC: The manifest names the admin (whoever shared the project first). The admin owns the
//       remote repo and manages members there; MinuteMind enforces nothing beyond recording it.
// Dependents: Sources/App/Models/Project.swift (Project.shared), RecordingSession.swift
//             (publication), Sources/App/Services/ProjectRepositoryService.swift (layout),
//             Sources/App/Services/SharedProjectSyncService.swift (status),
//             Sources/App/ViewModels/AppViewModel+SharedPublishing.swift, +SharedSetup.swift,
//             the pill's saved card, the sidebar and the workspace views.
// Notes: Everything under private/ is gitignored by one fixed .gitignore line, never per item, so
//        the shared .gitignore never reveals what is private.
//        The shared project id is the project UUID itself: the workspace folder is named after
//        it, so a member who joins creates the local project with the same id.
//        In a Shared Project the mirror indexes (.minutemind/meetings.json, recordings.json) are
//        local: each member indexes only their own sessions, and the folder is the record for
//        everyone else's.
//        jobs/ is gitignored as a whole: a job's prompt and its run results can draw on private/,
//        so jobs are each member's own and run only on the Mac that holds them.

import Foundation

/// Whether a meeting or quick recording in a Shared Project goes to the other members.
/// Nil on a session means "not decided", which counts as private. Meaningless in a Private project.
enum MeetingPublication: String, Codable, Equatable {
    case published
    case keptPrivate = "private"
}

/// Set on a Project once it is shared (after the migration skill pushed it, or after joining).
struct SharedProjectInfo: Codable, Equatable {
    /// The git remote of the workspace repo (`origin`), e.g. git@github.com:org/acme-minutemind.git
    var remoteURL: String
    var sharedAt: Date
}

/// `.minutemind/project.json` in a Shared Project's repo (tracked, so every member reads it).
/// Manifests written by older builds also hold a `colorHex`; it is ignored when read.
struct SharedProjectManifest: Codable, Equatable {
    struct Member: Codable, Equatable {
        var name: String
        var joinedAt: Date
    }

    struct CodeRepo: Codable, Equatable {
        var url: String
        /// Folder name under the workspace's gitignored code/.
        var folder: String
    }

    var projectID: UUID
    var name: String
    /// Display name of whoever shared the project first.
    var admin: String
    var members: [Member]
    var codeRepos: [CodeRepo]

    static let relativePath = ".minutemind/project.json"

    static func load(from repo: URL) -> SharedProjectManifest? {
        let url = repo.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SharedProjectManifest.self, from: data)
    }

    func save(to repo: URL) throws {
        let url = repo.appendingPathComponent(Self.relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Adds the member if no member has that name yet. Returns true when it changed.
    @discardableResult
    mutating func addMember(_ name: String, at date: Date = Date()) -> Bool {
        guard !members.contains(where: { $0.name == name }) else { return false }
        members.append(Member(name: name, joinedAt: date))
        return true
    }
}

/// Folder layout of a Shared Project's workspace.
enum SharedProjectLayout {
    /// Gitignored, never leaves the Mac.
    static let privateFolder = "private"
    static let privateKnowledgeFolder = "private/knowledge"
    /// The one line every Shared Project's .gitignore carries for private content.
    static let gitignoreEntry = "/private/"
    /// Local mirror indexes, ignored in Shared Projects.
    static let localIndexEntries = ["/.minutemind/meetings.json", "/.minutemind/recordings.json"]
    /// Scheduled jobs and their run results are each member's own and never shared.
    static let jobsFolder = "jobs"
    static let jobsGitignoreEntry = "/jobs/"
    /// Every line a Shared Project's .gitignore must carry.
    static let gitignoreEntries = [gitignoreEntry] + localIndexEntries + [jobsGitignoreEntry]

    /// The area folder relative to the repo root a session is mirrored into: "meetings" or
    /// "recordings" when published (or in a Private project), "private/meetings" or
    /// "private/recordings" when it stays private in a Shared Project.
    static func areaFolder(isQuickRecording: Bool, isSharedProject: Bool, publication: MeetingPublication?) -> String {
        let base = isQuickRecording ? "recordings" : "meetings"
        guard isSharedProject, publication != .published else { return base }
        return "\(privateFolder)/\(base)"
    }

    /// The knowledge folder an item's facts go to.
    static func knowledgeFolder(isSharedProject: Bool, publication: MeetingPublication?) -> String {
        guard isSharedProject, publication != .published else { return "knowledge" }
        return privateKnowledgeFolder
    }

    /// True for a path (relative to the repo root) inside private/.
    static func isPrivate(_ relativePath: String) -> Bool {
        relativePath == privateFolder || relativePath.hasPrefix(privateFolder + "/")
    }
}

/// The user's display name for Shared Projects: shown in the members list and appended to the
/// folder names of meetings and recordings they publish. Set in Settings; asked once on the
/// first share or join. Changing it later leaves existing folders as they are.
enum ContributorName {
    static let defaultsKey = "mm.displayName"

    static var current: String? {
        get {
            let value = UserDefaults.standard.string(forKey: defaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        }
        set { UserDefaults.standard.set(newValue?.trimmingCharacters(in: .whitespacesAndNewlines), forKey: defaultsKey) }
    }

    /// Folder-name form of a display name: lowercase ASCII slug, e.g. "Robin S." -> "robin-s".
    @MainActor static func folderSuffix(_ name: String) -> String {
        ProjectRepositoryService.slug(name)
    }
}

/// What the sidebar icon and the workspace branch row show for a Shared Project.
struct SharedSyncStatus: Equatable {
    enum State: Equatable {
        case idle
        case syncing
        /// Something needs attention (no network, auth failed, a conflict the app could not
        /// replay). The message is shown as the tooltip and in the branch row.
        case problem(String)
    }

    var state: State = .idle
    var lastSynced: Date?
    /// Files over the size limit the last sync kept on this Mac.
    var heldBack: [SharedHeldBackFile] = []

    var hasProblem: Bool {
        if case .problem = state { return true }
        return false
    }
}
