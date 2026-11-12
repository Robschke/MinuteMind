// Purpose: MCPSharedProjectTools, the MCP tool the share-project migration skill calls when it
//          has pushed the fresh shared history: complete_shared_project_setup turns the project
//          into a Shared Project in the app after checking the repo.
// Dependencies: Sources/App/ViewModels/AppViewModel+SharedSetup.swift (completeSharedProjectSetup),
//               Sources/App/Services/ToolExecutor.swift (ToolError)
// Used by: Sources/App/Services/MCP/MinuteMindMCPServer.swift,
//          Sources/App/Services/SharedProjectSkill.swift (the skill names the tool)
// RBAC: none inside the app; every MCP client holding the bearer token may call it. It can only
//       flip a project whose workspace already has a pushed shared main with a matching manifest,
//       so a stray call cannot share anything that was not pushed already.
// Notes: Same OpenAI function shape as MCPJobTools. The checks run git (ls-remote goes over the
//        network) off the main actor; failures come back as tool errors with a fix-it text.

import Foundation

@MainActor
struct MCPSharedProjectTools {
    let appViewModel: AppViewModel

    static let names: Set<String> = ["complete_shared_project_setup"]

    static var definitions: [[String: Any]] {
        [
            [
                "type": "function",
                "function": [
                    "name": "complete_shared_project_setup",
                    "description": "Finish turning a project into a Shared Project, called by the share-project skill after it pushed the fresh shared history. Checks that the workspace's origin is remote_url, that .minutemind/project.json names this project and that main is pushed, then records which of the user's meetings and recordings were published and switches the project to Shared in MinuteMind.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "project_id": ["type": "string", "description": "Project UUID (see list_projects)."],
                            "remote_url": ["type": "string", "description": "The exact URL of the workspace's origin (git remote get-url origin)."],
                        ] as [String: Any],
                        "required": ["project_id", "remote_url"],
                    ] as [String: Any],
                ] as [String: Any],
            ],
        ]
    }

    func execute(toolName: String, arguments: [String: Any]) async throws -> String {
        guard toolName == "complete_shared_project_setup" else { throw ToolError.invalidArguments("Unknown tool \(toolName)") }
        guard let raw = arguments["project_id"] as? String else { throw ToolError.invalidArguments("project_id is required") }
        guard let projectID = UUID(uuidString: raw) else { throw ToolError.invalidArguments("project_id is not a valid UUID") }
        guard let remoteURL = (arguments["remote_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !remoteURL.isEmpty else {
            throw ToolError.invalidArguments("remote_url is required")
        }
        return try await appViewModel.completeSharedProjectSetup(projectID: projectID, remoteURL: remoteURL)
    }
}
