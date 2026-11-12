// Purpose: Notes tab inside ProjectDetailView — lists EventNotes linked to a project with
//          keyword search, sort, tag filtering, inline creation, and delete.
// Dependencies: Sources/App/ViewModels/AppViewModel.swift, Sources/App/Models/EventNote.swift,
//               Sources/App/Components/DesignSystem.swift
// Used by: Sources/App/Views/CalendarEventDetailView.swift (not shown in projects any more)
// Notes: Notes can be created from calendar events (CalendarEventDetailView) or manually
//        via the "+ New Note" button. Manual notes have a nil eventId.
//        Tag chips in the detail sheet support drag-and-drop reordering.

import SwiftUI
import UniformTypeIdentifiers

enum NoteSort: String, CaseIterable {
    case eventDate  = "Date"
    case updatedAt  = "Last Updated"
    case eventTitle = "Title"
}

struct ProjectNotesTabView: View {
    var viewModel: AppViewModel
    let project: Project

    @State private var sort: NoteSort = .eventDate
    @State private var sortAscending = false
    @State private var selectedTag: String? = nil
    @State private var searchText: String = ""
    @State private var selectedNote: EventNote? = nil

    private var notes: [EventNote] { viewModel.notesForProject(project.id) }

    private var allTags: [String] {
        Array(Set(notes.flatMap { $0.tags })).sorted()
    }

    private var filteredNotes: [EventNote] {
        var result = notes

        // Keyword search across title and content
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter {
                $0.eventTitle.lowercased().contains(q) ||
                $0.content.lowercased().contains(q)
            }
        }

        // Tag filter
        if let tag = selectedTag {
            result = result.filter { $0.tags.contains(tag) }
        }

        result = result.sorted { a, b in
            switch sort {
            case .eventDate:
                return sortAscending ? a.eventDate < b.eventDate : a.eventDate > b.eventDate
            case .updatedAt:
                return sortAscending ? a.updatedAt < b.updatedAt : a.updatedAt > b.updatedAt
            case .eventTitle:
                return sortAscending
                    ? a.eventTitle.localizedCompare(b.eventTitle) == .orderedAscending
                    : a.eventTitle.localizedCompare(b.eventTitle) == .orderedDescending
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().overlay(DesignSystem.Colors.divider)
            toolbar
            Divider().overlay(DesignSystem.Colors.divider)

            if filteredNotes.isEmpty {
                emptyState
            } else {
                notesList
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: DesignSystem.Dimensions.spacingS) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            TextField("Search notes…", text: $searchText)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.callout)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DesignSystem.Dimensions.spacingXL)
        .padding(.vertical, DesignSystem.Dimensions.spacingS)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: DesignSystem.Dimensions.spacingM) {
            // Sort picker
            Picker("Sort by", selection: $sort) {
                ForEach(NoteSort.allCases, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)

            Button {
                sortAscending.toggle()
            } label: {
                Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                    .imageScale(.small)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .help(sortAscending ? "Ascending" : "Descending")

            if !allTags.isEmpty {
                Divider().frame(height: 16)

                // Tag filter chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DesignSystem.Dimensions.spacingXS) {
                        filterChip("All", isSelected: selectedTag == nil) {
                            selectedTag = nil
                        }
                        ForEach(allTags, id: \.self) { tag in
                            filterChip(tag, isSelected: selectedTag == tag) {
                                selectedTag = selectedTag == tag ? nil : tag
                            }
                        }
                    }
                }
            }

            Spacer()

            Button {
                let note = viewModel.createManualNote(projectId: project.id)
                selectedNote = note
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, DesignSystem.Dimensions.spacingXL)
        .padding(.vertical, DesignSystem.Dimensions.spacingS)
    }

    private func filterChip(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : DesignSystem.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentColor.opacity(0.12) : DesignSystem.Colors.card)
                        .overlay(
                            Capsule().stroke(
                                isSelected ? Color.accentColor.opacity(0.4) : DesignSystem.Colors.divider,
                                lineWidth: 1
                            )
                        )
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Notes List

    private var notesList: some View {
        ScrollView {
            LazyVStack(spacing: DesignSystem.Dimensions.spacingS) {
                ForEach(filteredNotes) { note in
                    noteRow(note)
                        .onTapGesture { selectedNote = note }
                }
            }
            .padding(DesignSystem.Dimensions.spacingL)
        }
        .sheet(item: $selectedNote) { note in
            NoteDetailSheet(note: note, viewModel: viewModel) {
                selectedNote = nil
            }
            .frame(
                minWidth: 560, idealWidth: 700, maxWidth: .infinity,
                minHeight: 460, idealHeight: 580, maxHeight: .infinity
            )
            .resizableSheet()
        }
    }

    @ViewBuilder
    private func noteRow(_ note: EventNote) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingXS) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if note.isManual {
                            Image(systemName: "pencil")
                                .font(.system(size: 10))
                                .foregroundStyle(DesignSystem.Colors.textTertiary)
                        }
                        Text(note.eventTitle)
                            .font(DesignSystem.Typography.callout.weight(.medium))
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                    }
                    if note.isManual {
                        Text("Manual note")
                            .font(DesignSystem.Typography.caption1)
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                    } else {
                        Text(note.eventDate.formatted(.dateTime.month(.abbreviated).day().year()))
                            .font(DesignSystem.Typography.caption1)
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                    }
                }
                Spacer()
                Text(note.updatedAt.formatted(.relative(presentation: .named)))
                    .font(DesignSystem.Typography.caption1)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }

            if !note.content.isEmpty {
                Text(note.content)
                    .font(DesignSystem.Typography.caption1)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)
            }

            if !note.tags.isEmpty {
                HStack(spacing: DesignSystem.Dimensions.spacingXS) {
                    ForEach(note.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.1)))
                    }
                }
            }
        }
        .padding(DesignSystem.Dimensions.spacingM)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                .fill(DesignSystem.Colors.card)
        )
        .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Dimensions.spacingM) {
            Spacer()
            Image(systemName: "note.text")
                .font(.system(size: 36))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            Text(searchText.isEmpty && selectedTag == nil ? "No notes yet" : "No matching notes")
                .font(DesignSystem.Typography.callout.weight(.medium))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            if searchText.isEmpty && selectedTag == nil {
                Text("Click \"New Note\" to write one, or open an event in the Calendar view to add notes from there.")
                    .font(DesignSystem.Typography.caption1)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                Button {
                    let note = viewModel.createManualNote(projectId: project.id)
                    selectedNote = note
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Note Detail Sheet

private struct NoteDetailSheet: View {
    let note: EventNote
    var viewModel: AppViewModel
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var content: String = ""
    @State private var tags: [String] = []
    @State private var newTag: String = ""
    @State private var showTagField = false
    @State private var showDeleteConfirm = false
    /// Tag being dragged (its string value).
    @State private var draggingTag: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(DesignSystem.Colors.divider)
            editor
            Divider().overlay(DesignSystem.Colors.divider)
            tagsRow
        }
        .onAppear {
            title = note.eventTitle
            content = note.content
            tags = note.tags
        }
        .onChange(of: content) { save() }
        .onChange(of: tags) { save() }
        .confirmationDialog("Delete this note?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                viewModel.deleteNote(note)
                onDelete()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                if note.isManual {
                    TextField("Note title", text: $title)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .textFieldStyle(.plain)
                        .onChange(of: title) { save() }
                } else {
                    Text(note.eventTitle)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(note.eventDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                        .font(DesignSystem.Typography.caption1)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }
            Spacer()
            HStack(spacing: DesignSystem.Dimensions.spacingS) {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Delete note")

                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(DesignSystem.Dimensions.spacingXL)
    }

    // MARK: - Editor

    private var editor: some View {
        TextEditor(text: $content)
            .font(DesignSystem.Typography.callout)
            .padding(DesignSystem.Dimensions.spacingL)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tags Row

    private var tagsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignSystem.Dimensions.spacingXS) {
                Image(systemName: "tag")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.textTertiary)

                ForEach(tags, id: \.self) { tag in
                    tagChip(tag)
                        // Drag this chip
                        .draggable(tag) {
                            Text(tag)
                                .font(.system(size: 11))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                        // Drop onto this chip to reorder
                        .dropDestination(for: String.self) { dropped, _ in
                            guard let src = dropped.first, src != tag else { return false }
                            var reordered = tags
                            reordered.removeAll { $0 == src }
                            if let destIdx = reordered.firstIndex(of: tag) {
                                reordered.insert(src, at: destIdx)
                            } else {
                                reordered.append(src)
                            }
                            tags = reordered
                            return true
                        }
                }

                if showTagField {
                    TextField("tag", text: $newTag)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .frame(width: 80)
                        .onSubmit { commitTag() }
                } else {
                    Button {
                        showTagField = true
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignSystem.Dimensions.spacingL)
            .padding(.vertical, DesignSystem.Dimensions.spacingM)
        }
    }

    // MARK: - Helpers

    private func tagChip(_ tag: String) -> some View {
        HStack(spacing: 3) {
            Text(tag).font(.system(size: 11)).foregroundStyle(DesignSystem.Colors.textSecondary)
            Button {
                tags.removeAll { $0 == tag }
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(
            Capsule().fill(DesignSystem.Colors.card)
                .overlay(Capsule().stroke(DesignSystem.Colors.divider, lineWidth: 1))
        )
    }

    private func commitTag() {
        let t = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty && !tags.contains(t) { tags.append(t) }
        newTag = ""
        showTagField = false
    }

    private func save() {
        var updated = note
        if note.isManual {
            updated.eventTitle = title.isEmpty ? "Untitled Note" : title
        }
        updated.content = content
        updated.tags = tags
        viewModel.upsertNote(updated)
    }
}
