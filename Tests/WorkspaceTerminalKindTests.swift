// Purpose: Tests for plain terminal tabs next to Claude sessions in the workspace strips: the
//          separate per-project limits, numbering per kind, and the login shell they start.
// Dependencies: Sources/App/Supporting/WorkspaceTerminalStore.swift (Kind, hasRoom, nextNumber),
//               Sources/App/ViewModels/AppViewModel.swift (loginShell)
// Notes: Only pure helpers are tested; creating sessions would start real processes.

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("WorkspaceTerminalKind Tests")
@MainActor
struct WorkspaceTerminalKindTests {
    private typealias Kind = WorkspaceTerminalSession.Kind

    @Test func terminalsDoNotCountTowardTheClaudeLimit() {
        let sixClaude = Array(repeating: Kind.claude(model: "opus"), count: WorkspaceTerminalStore.maxSessions)
        #expect(!WorkspaceTerminalStore.hasRoom(for: .claude(model: "sonnet"), among: sixClaude))
        #expect(WorkspaceTerminalStore.hasRoom(for: .terminal, among: sixClaude))
    }

    @Test func terminalsHaveTheirOwnLimit() {
        let terminals = Array(repeating: Kind.terminal, count: WorkspaceTerminalStore.maxTerminals)
        #expect(!WorkspaceTerminalStore.hasRoom(for: .terminal, among: terminals))
        #expect(WorkspaceTerminalStore.hasRoom(for: .claude(model: "opus"), among: terminals))
        #expect(WorkspaceTerminalStore.hasRoom(for: .terminal, among: Array(terminals.dropLast())))
    }

    @Test func numbersReuseTheLowestFreeOne() {
        #expect(WorkspaceTerminalStore.nextNumber(used: []) == 1)
        #expect(WorkspaceTerminalStore.nextNumber(used: [1, 3]) == 2)
        #expect(WorkspaceTerminalStore.nextNumber(used: [1, 2, 3]) == 4)
    }

    @Test func kindTellsTerminalsApart() {
        #expect(Kind.terminal.isTerminal)
        #expect(!Kind.claude(model: "opus").isTerminal)
        #expect(Kind.claude(model: "opus") != Kind.claude(model: "sonnet"))
    }

    @Test func loginShellIsAnExecutable() {
        let shell = AppViewModel.loginShell()
        #expect(shell.hasPrefix("/"))
        #expect(FileManager.default.isExecutableFile(atPath: shell))
    }
}
