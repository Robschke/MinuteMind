// Purpose: Resolves a Shared Project's sync conflicts without touching the working folder: the
//          merge of this Mac's commits and the remote is computed in memory (git merge-tree), each
//          conflicted file is resolved by a rule or by Claude, and the result is committed as a
//          merge commit and pushed. The sync then brings the folder up to date as usual.
// Dependencies: Sources/App/Services/SharedProjectSyncService.swift (SharedRepoGit.run, the sync
//               loop that calls this), Sources/App/Services/ClaudeCodeService.swift (chat, for the
//               text merge)
// RBAC: None (membership is enforced by the git host).
// Dependents: Sources/App/Services/SharedProjectSyncService.swift (SharedProjectSync.performSync),
//             Tests/SharedProjectSyncMergeTests.swift
// Notes: Rules: a file deleted on one side and changed on the other keeps the changed version
//        (an edit wins over a deletion); deleted on both sides stays deleted; changed on both
//        sides: identical results are taken as they are, text is merged by Claude, anything else
//        (binary, very large, renames, file/folder clashes) stops the sync with
//        "Sync conflict in <file>" as before.
//        The merge never runs in the working folder, so files being edited are never left with
//        conflict markers and the app's own commits never pause for it.
//        In merge-tree's output stage 2 is this Mac (HEAD) and stage 3 the remote.

import Foundation

/// One side of a conflicted file: its mode and blob.
struct SharedMergeSide: Equatable, Sendable {
    let mode: String
    let blob: String
}

/// A conflicted file: what the common ancestor, this Mac and the remote hold (nil: no file).
struct SharedMergeConflict: Equatable, Sendable {
    let path: String
    var base: SharedMergeSide?
    var mine: SharedMergeSide?
    var theirs: SharedMergeSide?
}

/// The in-memory merge of this Mac's branch and the remote.
struct SharedMergePlan: Equatable, Sendable {
    let head: String
    let upstream: String
    /// merge-tree's result tree (conflicted files hold conflict markers there).
    let tree: String
    let conflicts: [SharedMergeConflict]
    /// Paths of conflicts the rules cannot resolve (renames, file/folder clashes).
    let unsupported: [String]

    var firstPath: String { unsupported.first ?? conflicts.first?.path ?? "" }
}

/// The three versions Claude merges.
struct SharedTextMerge: Equatable, Sendable {
    let path: String
    let base: String?
    let mine: String
    let theirs: String
}

/// How one conflicted file is resolved.
enum SharedMergeResolution: Equatable, Sendable {
    case keep(SharedMergeSide)
    case delete
    case text(SharedTextMerge, mode: String)
    case unresolvable
}

enum SharedMergeRules {
    /// Larger sides are not sent to Claude.
    static let maxTextCharacters = 200_000

    /// What the rules make of a conflict; `read` returns a blob's text, or nil for binary content.
    static func resolve(_ conflict: SharedMergeConflict, read: (String) -> String?) -> SharedMergeResolution {
        switch (conflict.mine, conflict.theirs) {
        case (nil, nil):
            return conflict.base == nil ? .unresolvable : .delete
        case (nil, let theirs?):
            return conflict.base == nil ? .unresolvable : .keep(theirs)
        case (let mine?, nil):
            return conflict.base == nil ? .unresolvable : .keep(mine)
        case (let mine?, let theirs?):
            if mine.blob == theirs.blob { return .keep(mine) }
            guard mine.mode == theirs.mode, mine.mode.hasPrefix("1006") || mine.mode.hasPrefix("1007"),
                  let mineText = read(mine.blob), let theirsText = read(theirs.blob),
                  mineText.count <= maxTextCharacters, theirsText.count <= maxTextCharacters else { return .unresolvable }
            var baseText: String?
            if let base = conflict.base {
                guard let text = read(base.blob), text.count <= maxTextCharacters else { return .unresolvable }
                baseText = text
            }
            return .text(SharedTextMerge(path: conflict.path, base: baseText, mine: mineText, theirs: theirsText), mode: mine.mode)
        }
    }

    /// The merge commit's message: which files were merged by Claude and which edits were kept.
    static func commitMessage(for resolutions: [(path: String, resolution: SharedMergeResolution)]) -> String {
        let merged = resolutions.filter { if case .text = $0.resolution { return true }; return false }.map(\.path)
        let kept = resolutions.filter { if case .keep = $0.resolution { return true }; return false }.map(\.path)
        let deleted = resolutions.filter { $0.resolution == .delete }.map(\.path)
        var lines = ["Sync: merge with the other members' changes", ""]
        if !merged.isEmpty { lines.append("Merged by Claude: " + merged.joined(separator: ", ")) }
        if !kept.isEmpty { lines.append("Kept (edited on one side, deleted or unchanged on the other): " + kept.joined(separator: ", ")) }
        if !deleted.isEmpty { lines.append("Deleted on both sides: " + deleted.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}

/// The text merge by Claude.
enum SharedTextMerger {
    static let systemPrompt = """
        You merge two edited versions of one text file from a workspace that several people share \
        through git. You get the common ancestor (if any), version A and version B. Write the one \
        file that keeps every change from both versions: where they changed different parts, take \
        both; where they changed the same part, combine them so nothing either person added is \
        lost (in Markdown knowledge files keep both bullets and every source in parentheses, and \
        drop a bullet only when both versions dropped it). Keep the file's format, order and \
        style. Never write conflict markers, comments about the merge or anything else. Answer \
        with the merged file only, between a line <merged> and a line </merged>.
        """

    static func prompt(for merge: SharedTextMerge) -> String {
        var parts = ["File: \(merge.path)"]
        if let base = merge.base { parts.append("<ancestor>\n\(base)\n</ancestor>") }
        else { parts.append("(No common ancestor: both versions created the file.)") }
        parts.append("<version_a>\n\(merge.mine)\n</version_a>")
        parts.append("<version_b>\n\(merge.theirs)\n</version_b>")
        return parts.joined(separator: "\n\n")
    }

    enum MergeError: Error, Equatable {
        case noMergedFile
        case conflictMarkers
    }

    /// The file between <merged> and </merged>, refused when it still holds conflict markers.
    static func mergedFile(in answer: String) throws -> String {
        guard let start = answer.range(of: "<merged>\n") ?? answer.range(of: "<merged>"),
              let end = answer.range(of: "</merged>", options: .backwards), start.upperBound <= end.lowerBound else {
            throw MergeError.noMergedFile
        }
        var text = String(answer[start.upperBound..<end.lowerBound])
        if text.hasSuffix("\n\n") { text.removeLast() }
        let markers = text.split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.hasPrefix("<<<<<<< ") || $0.hasPrefix(">>>>>>> ") || $0 == "=======" }
        if markers { throw MergeError.conflictMarkers }
        return text
    }

    /// Asks Claude Code (headless, no tools) for the merged file.
    static func mergeWithClaude(_ merge: SharedTextMerge, model: String) async throws -> String {
        let answer = try await ClaudeCodeService.chat(system: systemPrompt, user: prompt(for: merge), model: model)
        return try mergedFile(in: answer)
    }
}

extension SharedRepoGit {
    /// merge-tree's message types the rules can handle; any other CONFLICT type is unsupported.
    private static let supportedConflictTypes: Set<String> = ["CONFLICT (contents)", "CONFLICT (modify/delete)", "CONFLICT (add/add)"]

    /// Merges HEAD and `upstream` in memory. Nil when merge-tree fails or reports no conflict
    /// (the rebase that failed before then had another reason).
    static func mergePlan(repo: URL, upstream: String) -> SharedMergePlan? {
        let head = head(of: repo)
        let upstreamID = run(["rev-parse", "--verify", "--quiet", upstream], in: repo).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty, !upstreamID.isEmpty else { return nil }
        let result = run(["merge-tree", "--write-tree", "-z", head, upstreamID], in: repo)
        // Exit 1 means conflicts; anything else is either a clean merge or an error.
        guard result.status == 1 else { return nil }
        let fields = result.stdout.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard let tree = fields.first, !tree.isEmpty else { return nil }

        var conflicts: [String: SharedMergeConflict] = [:]
        var order: [String] = []
        var index = 1
        while index < fields.count, !fields[index].isEmpty {
            // "<mode> <object> <stage>\t<path>"
            let entry = fields[index]
            index += 1
            guard let tab = entry.firstIndex(of: "\t") else { continue }
            let meta = entry[..<tab].split(separator: " ").map(String.init)
            let path = String(entry[entry.index(after: tab)...])
            guard meta.count == 3 else { continue }
            let side = SharedMergeSide(mode: meta[0], blob: meta[1])
            if conflicts[path] == nil { order.append(path); conflicts[path] = SharedMergeConflict(path: path) }
            switch meta[2] {
            case "1": conflicts[path]?.base = side
            case "2": conflicts[path]?.mine = side
            case "3": conflicts[path]?.theirs = side
            default: break
            }
        }

        // Informational messages: "<count>\0<path>...\0<type>\0<message>\0".
        var unsupported: [String] = []
        index += 1
        while index < fields.count, let count = Int(fields[index]) {
            let paths = Array(fields[(index + 1)..<min(fields.count, index + 1 + count)])
            let typeIndex = index + 1 + count
            guard typeIndex + 1 < fields.count else { break }
            let type = fields[typeIndex]
            if type.hasPrefix("CONFLICT"), !supportedConflictTypes.contains(type) {
                unsupported.append(contentsOf: paths.filter { !unsupported.contains($0) })
            }
            index = typeIndex + 2
        }
        guard !order.isEmpty || !unsupported.isEmpty else { return nil }
        return SharedMergePlan(head: head, upstream: upstreamID, tree: tree,
                               conflicts: order.compactMap { conflicts[$0] }, unsupported: unsupported)
    }

    /// A blob's text, or nil when it is binary (holds a NUL byte or is not UTF-8).
    static func blobText(_ blob: String, in repo: URL) -> String? {
        let output = runData(["cat-file", "blob", blob], in: repo)
        guard output.succeeded, !output.data.contains(0) else { return nil }
        return String(data: output.data, encoding: .utf8)
    }

    enum MergePushOutcome: Equatable, Sendable {
        case pushed
        /// Someone pushed first; sync again on the new state.
        case rejected
        case failed(String)
    }

    /// Writes the resolved files over merge-tree's result in a temporary index, commits the tree
    /// with HEAD and the remote as parents and pushes it to `branch`. `merged` holds the text
    /// for each `.text` resolution.
    static func commitAndPushMerge(
        repo: URL, branch: String, plan: SharedMergePlan,
        resolutions: [(path: String, resolution: SharedMergeResolution)],
        merged: [String: String], message: String
    ) -> MergePushOutcome {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinuteMind-SyncMerge-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let index = ["GIT_INDEX_FILE": scratch.appendingPathComponent("index").path]

        let read = run(["read-tree", plan.tree], in: repo, environment: index)
        guard read.succeeded else { return .failed("Could not merge: \(firstLine(read.stderr))") }
        for (offset, item) in resolutions.enumerated() {
            let update: WorkspaceGit.Output
            switch item.resolution {
            case .keep(let side):
                update = run(["update-index", "--add", "--cacheinfo", "\(side.mode),\(side.blob),\(item.path)"], in: repo, environment: index)
            case .delete:
                update = run(["update-index", "--force-remove", "--", item.path], in: repo, environment: index)
            case .text(_, let mode):
                guard let text = merged[item.path] else { return .failed("Could not merge \(item.path)") }
                let file = scratch.appendingPathComponent("merged-\(offset)")
                do { try text.write(to: file, atomically: true, encoding: .utf8) } catch {
                    return .failed("Could not merge \(item.path): \(error.localizedDescription)")
                }
                let blob = run(["hash-object", "-w", "--path=\(item.path)", file.path], in: repo)
                    .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !blob.isEmpty else { return .failed("Could not merge \(item.path)") }
                update = run(["update-index", "--add", "--cacheinfo", "\(mode),\(blob),\(item.path)"], in: repo, environment: index)
            case .unresolvable:
                return .failed("Sync conflict in \(item.path)")
            }
            guard update.succeeded else { return .failed("Could not merge \(item.path): \(firstLine(update.stderr))") }
        }
        let tree = run(["write-tree"], in: repo, environment: index).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tree.isEmpty else { return .failed("Could not merge: git could not write the merged files") }
        let commit = run(["commit-tree", tree, "-p", plan.head, "-p", plan.upstream, "-m", message], in: repo)
        let commitID = commit.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard commit.succeeded, !commitID.isEmpty else { return .failed("Could not merge: \(firstLine(commit.stderr))") }
        let push = run(["push", "--quiet", remote, "\(commitID):refs/heads/\(branch)"], in: repo)
        if push.succeeded { return .pushed }
        return isRejection(push.stderr) ? .rejected : .failed("Could not push: \(firstLine(push.stderr))")
    }
}
