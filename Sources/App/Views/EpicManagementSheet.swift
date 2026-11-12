/// Epic CRUD sheet for managing epics within a project (create, rename, recolor, reorder, delete).
/// Depends on: AppViewModel, Epic.swift, Project.swift (defaultColors), DesignSystem
/// Used by: WorkboardView

import SwiftUI

struct EpicManagementSheet: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss
    let project: Project

    @State private var newEpicTitle = ""
    @State private var selectedColor = Project.defaultColors[0]
    @State private var editingEpic: Epic?
    @State private var editTitle = ""
    @State private var editSummary = ""
    @State private var editColor = ""
    @State private var epicToDelete: Epic?

    private var epics: [Epic] {
        viewModel.epicsForProject(project.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Manage Epics")
                    .font(DesignSystem.Typography.title3)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(20)

            Divider()

            // New epic input
            HStack(spacing: 8) {
                colorPicker(selection: $selectedColor)

                TextField("New epic name...", text: $newEpicTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addEpic() }

                Button {
                    addEpic()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(newEpicTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)

            Divider()

            // Epic list
            if epics.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.3.group")
                        .font(.largeTitle)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                    Text("No epics yet")
                        .font(DesignSystem.Typography.callout)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Text("Epics group related tasks together on the board.")
                        .font(DesignSystem.Typography.caption1)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(epics) { epic in
                        epicRow(epic)
                    }
                    .onMove { source, destination in
                        moveEpics(from: source, to: destination)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 480, height: 400)
        .alert("Delete Epic?", isPresented: Binding(
            get: { epicToDelete != nil },
            set: { if !$0 { epicToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { epicToDelete = nil }
            Button("Delete", role: .destructive) {
                if let epic = epicToDelete {
                    viewModel.deleteEpic(epic)
                    epicToDelete = nil
                }
            }
        } message: {
            Text("Tasks assigned to this epic will become unassigned, not deleted.")
        }
    }

    // MARK: - Epic Row

    private func epicRow(_ epic: Epic) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(hex: epic.colorHex))
                .frame(width: 12, height: 12)

            if editingEpic?.id == epic.id {
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        colorPicker(selection: $editColor)
                        TextField("Title", text: $editTitle)
                            .textFieldStyle(.roundedBorder)
                    }
                    TextField("Summary (optional)", text: $editSummary)
                        .textFieldStyle(.roundedBorder)
                        .font(DesignSystem.Typography.caption1)
                    HStack {
                        Button("Cancel") {
                            editingEpic = nil
                        }
                        Spacer()
                        Button("Save") {
                            saveEpicEdit(epic)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(epic.title)
                        .font(DesignSystem.Typography.callout)
                    if !epic.summary.isEmpty {
                        Text(epic.summary)
                            .font(DesignSystem.Typography.caption1)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }

                Spacer()

                let taskCount = viewModel.tasks.filter { $0.epicID == epic.id }.count
                Text("\(taskCount) tasks")
                    .font(DesignSystem.Typography.caption2)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)

                Button {
                    editingEpic = epic
                    editTitle = epic.title
                    editSummary = epic.summary
                    editColor = epic.colorHex
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.plain)

                Button {
                    epicToDelete = epic
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Color Picker

    private func colorPicker(selection: Binding<String>) -> some View {
        Menu {
            ForEach(Project.defaultColors, id: \.self) { hex in
                Button {
                    selection.wrappedValue = hex
                } label: {
                    Label(hex, systemImage: selection.wrappedValue == hex ? "checkmark.circle.fill" : "circle.fill")
                }
                .tint(Color(hex: hex))
            }
        } label: {
            Circle()
                .fill(Color(hex: selection.wrappedValue))
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(DesignSystem.Colors.border, lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Actions

    private func addEpic() {
        let trimmed = newEpicTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        viewModel.createEpic(title: trimmed, projectID: project.id, colorHex: selectedColor)
        newEpicTitle = ""
    }

    private func saveEpicEdit(_ epic: Epic) {
        var updated = epic
        updated.title = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.summary = editSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.colorHex = editColor
        guard !updated.title.isEmpty else { return }
        viewModel.updateEpic(updated)
        editingEpic = nil
    }

    private func moveEpics(from source: IndexSet, to destination: Int) {
        var ordered = epics
        ordered.move(fromOffsets: source, toOffset: destination)
        for (i, var epic) in ordered.enumerated() {
            epic.sortOrder = i
            viewModel.updateEpic(epic)
        }
    }
}
