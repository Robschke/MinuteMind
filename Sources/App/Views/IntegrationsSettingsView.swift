// Purpose: IntegrationsSettingsView, the "Integrations" tab in the Settings sheet. Turns the local
//          MCP server on or off, sets its port, shows and rotates the access token, offers
//          ready-to-copy setup for Claude Code and Claude Desktop, and sets the display name for
//          Shared Projects.
// Dependencies: Sources/App/Services/MCP/MinuteMindMCPServer.swift (state, token, port),
//               Sources/App/ViewModels/AppViewModel.swift (mcpServer property),
//               Sources/App/Models/SharedProject.swift (ContributorName),
//               Sources/App/Views/SharedProjectSetupViews.swift (ContributorNameText)
// RBAC: None in the app. The token shown here grants full read, write and delete access to
//       every MCP client that holds it.
// Dependents: Sources/App/Views/MeetingMinutesSettingsView.swift (Integrations tab)
// Notes: The token is masked by default (safe during screen sharing) with an eye button to
//        reveal it; copy buttons always copy the real token. The setup snippets are masked the
//        same way. Regenerating the token asks for confirmation because it disconnects every
//        configured client. Claude Desktop only speaks stdio to local servers, so its snippet
//        uses the `mcp-remote` bridge, which needs Node.js.
//        The display name is saved as it is typed; an emptied field clears it, so the next share
//        or join asks again.

import AppKit
import SwiftUI

struct IntegrationsSettingsView: View {
    @Environment(AppViewModel.self) private var viewModel

    @State private var isTokenRevealed = false
    @State private var portText = ""
    @State private var showRegenerateDialog = false
    @State private var copiedItem: String?
    @State private var displayName = ContributorName.current ?? ""

    private var server: MinuteMindMCPServer { viewModel.mcpServer }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                serverSection
                Divider()
                tokenSection
                Divider()
                claudeCodeSection
                Divider()
                claudeDesktopSection
                Divider()
                sharedProjectsSection
                Spacer(minLength: 20)
            }
            .padding(24)
        }
        .onAppear {
            portText = String(server.port)
            displayName = ContributorName.current ?? ""
        }
        .confirmationDialog(
            "Generate a new access token?",
            isPresented: $showRegenerateDialog,
            titleVisibility: .visible
        ) {
            Button("Generate New Token", role: .destructive) {
                server.regenerateToken()
                isTokenRevealed = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every client that uses the current token loses access until you update its configuration.")
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        GroupBox(label: sectionLabel("MCP server", systemImage: "point.3.connected.trianglepath.dotted")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Allow MCP clients on this Mac to access MinuteMind", isOn: Binding(
                    get: { server.isEnabled },
                    set: { server.isEnabled = $0 }
                ))

                Text("Claude Code, Claude Desktop and other MCP clients can read and change meetings, transcripts, summaries, tasks, notes, calendar events, reminders and the knowledge base, including deleting them. The server only listens on this Mac (127.0.0.1).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    statusIndicator
                    Spacer()
                    Text("Port")
                        .font(.subheadline)
                    TextField("Port", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onSubmit(applyPort)
                    Button("Apply", action: applyPort)
                        .disabled(Int(portText) == server.port)
                }

                HStack(spacing: 8) {
                    Text(server.endpointURL)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    copyButton(id: "url", value: server.endpointURL)
                }
            }
            .padding(8)
        }
    }

    private var tokenSection: some View {
        GroupBox(label: sectionLabel("Access token", systemImage: "key.fill")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(isTokenRevealed ? server.token : maskedToken)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        isTokenRevealed.toggle()
                    } label: {
                        Image(systemName: isTokenRevealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(isTokenRevealed ? "Hide token" : "Show token")
                    copyButton(id: "token", value: server.token)
                }
                HStack {
                    Text("Clients send it as \"Authorization: Bearer <token>\". Anyone with this token has full access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showRegenerateDialog = true
                    } label: {
                        Label("Generate New Token", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
            .padding(8)
        }
    }

    private var claudeCodeSection: some View {
        GroupBox(label: sectionLabel("Claude Code", systemImage: "terminal")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Run this once in a terminal:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                snippet(id: "claude-code", display: claudeCodeCommand(token: displayToken), copy: claudeCodeCommand(token: server.token))
            }
            .padding(8)
        }
    }

    private var claudeDesktopSection: some View {
        GroupBox(label: sectionLabel("Claude Desktop", systemImage: "macwindow")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add this to ~/Library/Application Support/Claude/claude_desktop_config.json and restart Claude Desktop. Requires Node.js (npx).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                snippet(id: "claude-desktop", display: claudeDesktopConfig(token: displayToken), copy: claudeDesktopConfig(token: server.token))
            }
            .padding(8)
        }
    }

    private var sharedProjectsSection: some View {
        GroupBox(label: sectionLabel("Shared Projects", systemImage: "person.2.fill")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Display name")
                        .font(.subheadline)
                    TextField("Your name", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                        .onChange(of: displayName) { _, value in ContributorName.current = value }
                }
                Text(ContributorNameText.settingsExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var statusIndicator: some View {
        switch server.status {
        case .running:
            Label("Running · \(server.toolCount) tools", systemImage: "circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .starting:
            Label("Starting…", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .stopped:
            Label("Off", systemImage: "circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .failed(let message):
            Label("Failed: \(message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    private func snippet(id: String, display: String, copy: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(display)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            copyButton(id: id, value: copy)
        }
    }

    private func copyButton(id: String, value: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copiedItem = id
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if copiedItem == id { copiedItem = nil }
            }
        } label: {
            Image(systemName: copiedItem == id ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy")
    }

    private func sectionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
    }

    // MARK: - Helpers

    private var maskedToken: String { String(repeating: "•", count: 24) }

    private var displayToken: String { isTokenRevealed ? server.token : maskedToken }

    private func applyPort() {
        guard let value = Int(portText), (1024...65535).contains(value) else {
            portText = String(server.port)
            return
        }
        server.port = value
    }

    private func claudeCodeCommand(token: String) -> String {
        "claude mcp add --transport http minutemind \(server.endpointURL) --header \"Authorization: Bearer \(token)\""
    }

    private func claudeDesktopConfig(token: String) -> String {
        """
        {
          "mcpServers": {
            "minutemind": {
              "command": "npx",
              "args": ["-y", "mcp-remote", "\(server.endpointURL)", "--allow-http", "--header", "Authorization:${MINUTEMIND_AUTH}"],
              "env": { "MINUTEMIND_AUTH": "Bearer \(token)" }
            }
          }
        }
        """
    }
}
