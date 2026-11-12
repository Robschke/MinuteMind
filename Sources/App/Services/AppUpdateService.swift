// Purpose: AppUpdateService, finds the latest MinuteMind release on GitHub and updates the app by
//          running the published install.sh, which quits MinuteMind, replaces the .app in place
//          and opens the new version.
// Dependencies: install.sh at the repository root (download, quit, replace, reopen),
//               GitHub's releases API for Robschke/MinuteMind (tag "v<version>", asset MinuteMind.zip)
// Used by: Sources/App/Services/MCP/MCPUpdateTools.swift (check_for_update, update_app)
// Notes: The installer runs as a separate bash process so it survives MinuteMind quitting; it
//        starts after a short sleep so the MCP reply reaches the client first. It installs into
//        the folder the running app lives in (MINUTEMIND_INSTALL_DIR), so an app in
//        ~/Applications is replaced there instead of a second copy landing in /Applications.
//        Output goes to <Application Support>/MinuteMind/update.log for debugging.

import Foundation

enum AppUpdateService {
    static let repository = "Robschke/MinuteMind"
    static let installScriptURL = "https://raw.githubusercontent.com/\(repository)/main/install.sh"
    static let installCommand = "curl -fsSL \(installScriptURL) | bash"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    struct Release: Equatable {
        let version: String
        let page: URL
        let notes: String
        let published: Date?
    }

    enum UpdateError: LocalizedError {
        case noRelease
        case badResponse(Int)

        var errorDescription: String? {
            switch self {
            case .noRelease: "No MinuteMind release was found on GitHub."
            case .badResponse(let status): "GitHub answered with HTTP \(status) when asked for the latest release."
            }
        }
    }

    /// The version of the running app (CFBundleShortVersionString), "dev" outside an app bundle.
    static var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The folder holding the running MinuteMind.app, nil when it runs from a build folder (`swift run`).
    static var installFolder: URL? {
        let bundle = Bundle.main.bundleURL
        return bundle.pathExtension == "app" ? bundle.deletingLastPathComponent() : nil
    }

    static func latestRelease(session: URLSession = .shared) async throws -> Release {
        var request = URLRequest(url: latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw UpdateError.noRelease }
        guard status == 200 else { throw UpdateError.badResponse(status) }
        return try parseRelease(data)
    }

    /// Reads GitHub's release JSON: tag_name ("v0.2.0"), html_url, body, published_at.
    static func parseRelease(_ data: Data) throws -> Release {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, !tag.isEmpty
        else { throw UpdateError.noRelease }
        let page = (object["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage
        let published = (object["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return Release(version: normalized(tag), page: page, notes: object["body"] as? String ?? "", published: published)
    }

    /// True when `candidate` is a higher version than `current`, compared number by number
    /// ("0.10.0" > "0.9.1"; a missing part counts as 0). A non-numeric current version ("dev")
    /// is never older, so development builds are not offered a release.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = numbers(candidate), let old = numbers(current) else { return false }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// Starts install.sh for the app in `folder`; MinuteMind is quit and reopened by the script.
    static func startInstaller(into folder: URL, logFile: URL) throws {
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let log = try FileHandle(forWritingTo: logFile)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "sleep 2; /usr/bin/curl -fsSL '\(installScriptURL)' | /bin/bash"]
        var environment = ProcessInfo.processInfo.environment
        environment["MINUTEMIND_INSTALL_DIR"] = folder.path
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        try process.run()
    }

    private static func normalized(_ version: String) -> String {
        version.hasPrefix("v") || version.hasPrefix("V") ? String(version.dropFirst()) : version
    }

    private static func numbers(_ version: String) -> [Int]? {
        let parts = normalized(version).split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }
}
