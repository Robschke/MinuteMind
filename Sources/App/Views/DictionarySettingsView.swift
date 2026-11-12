// Purpose: DictionarySettingsView, the "Dictionary" tab in Settings: words, names and
//          abbreviations MinuteMind must get right, each with the forms it is misheard as
//          ("aus SEO" -> "Auth0"), like Wispr Flow's dictionary.
// Dependencies: Sources/App/Store/VocabularyStore.swift (entries, add/update/delete/restore),
//               Sources/App/ViewModels/AppViewModel.swift (vocabulary property)
// Used by: Sources/App/Views/MeetingMinutesSettingsView.swift (Dictionary tab)
// Notes: Decisions (with design review 3): an always-visible add row on top with labelled fields
//        (Return in either field adds; Add is deliberately not the window's default button, so
//        Return elsewhere never adds a half-typed word). Short or very common misheard forms get
//        a warning, because replacements apply everywhere. Rows open for editing on double click
//        or the context menu; editing validates (no empty word, no duplicate), Return saves,
//        Escape cancels. Delete is undoable for 5 s (Undo button or Cmd+Z). Search shows
//        "n of m" and a no-results state. Auto-learning from transcript edits is not built yet.

import SwiftUI

struct DictionarySettingsView: View {
    @Environment(AppViewModel.self) private var viewModel

    @State private var newTerm = ""
    @State private var newVariants = ""
    @State private var search = ""
    @State private var editingID: UUID?
    @State private var deleted: VocabularyEntry?
    @State private var undoTask: Task<Void, Never>?
    @FocusState private var termFocused: Bool

    private var store: VocabularyStore { viewModel.vocabulary }

    private var filtered: [VocabularyEntry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.entries }
        return store.entries.filter { entry in
            entry.term.localizedCaseInsensitiveContains(query)
                || entry.variants.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var countText: String {
        let total = store.entries.count
        if !search.trimmingCharacters(in: .whitespaces).isEmpty { return "\(filtered.count) of \(total)" }
        return total == 1 ? "1 entry" : "\(total) entries"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dictionary")
                    .font(.title3.weight(.semibold))
                Text("Names, abbreviations and jargon MinuteMind should always spell right. Add the forms speech recognition gets wrong, and new transcripts, the live transcript and quick dictation use the right spelling. Claude also uses the dictionary when it cleans up a transcript.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            addRow

            if !store.entries.isEmpty {
                HStack {
                    Text(countText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search", text: $search)
                            .textFieldStyle(.plain)
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(width: 220, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                }
            }

            if store.entries.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                Text("No entries match \u{201C}\(search)\u{201D}")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filtered) { entry in
                        DictionaryRow(
                            entry: entry,
                            isEditing: editingID == entry.id,
                            onEdit: { editingID = entry.id },
                            onSave: { updated in
                                try store.update(updated)
                                editingID = nil
                            },
                            onCancel: { editingID = nil },
                            onDelete: { delete(entry) })
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(24)
        .overlay(alignment: .bottom) { undoToast }
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Correct spelling").font(.caption).foregroundStyle(.secondary)
                    TextField("Auth0", text: $newTerm)
                        .textFieldStyle(.roundedBorder)
                        .focused($termFocused)
                        .onSubmit(add)
                }
                .frame(width: 220)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Heard as (optional, separate with commas)").font(.caption).foregroundStyle(.secondary)
                    TextField("aus SEO, auth zero", text: $newVariants)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                }
                Button("Add", action: add)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let warning = Self.riskWarning(newVariants, store: store) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Teach MinuteMind your words")
                .font(.system(size: 15, weight: .medium))
            Text("For example \u{201C}Auth0\u{201D} heard as \u{201C}aus SEO\u{201D}, or a colleague's name that keeps coming out wrong.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var undoToast: some View {
        if let deleted {
            HStack(spacing: 12) {
                Text("Deleted \u{201C}\(deleted.term)\u{201D}")
                Button("Undo") {
                    store.restore(deleted)
                    self.deleted = nil
                }
                .keyboardShortcut("z", modifiers: .command)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 12)
        }
    }

    private func add() {
        let variants = newVariants.split(separator: ",").map(String.init)
        guard store.add(term: newTerm, variants: variants) != nil else { return }
        newTerm = ""
        newVariants = ""
        search = ""
        termFocused = true
    }

    private func delete(_ entry: VocabularyEntry) {
        store.delete(entry.id)
        deleted = entry
        undoTask?.cancel()
        undoTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { deleted = nil }
        }
    }

    /// Replacements apply everywhere, so very short or common forms rewrite ordinary speech.
    static func riskWarning(_ variantsText: String, store: VocabularyStore, excluding id: UUID? = nil) -> String? {
        let common: Set<String> = ["and", "the", "und", "der", "die", "das", "max", "man", "mal", "ja", "so", "ok", "okay", "eben", "also", "aber"]
        for raw in variantsText.split(separator: ",") {
            let variant = raw.trimmingCharacters(in: .whitespaces)
            guard !variant.isEmpty else { continue }
            if variant.count <= 3 || common.contains(variant.lowercased()) {
                return "\u{201C}\(variant)\u{201D} is short or common. It will be replaced everywhere it appears."
            }
            if let owner = store.entries.first(where: { $0.id != id && $0.variants.contains { $0.caseInsensitiveCompare(variant) == .orderedSame } }) {
                return "\u{201C}\(variant)\u{201D} already becomes \u{201C}\(owner.term)\u{201D}."
            }
        }
        return nil
    }
}

private struct DictionaryRow: View {
    @Environment(AppViewModel.self) private var viewModel
    let entry: VocabularyEntry
    let isEditing: Bool
    let onEdit: () -> Void
    let onSave: (VocabularyEntry) throws -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @State private var term = ""
    @State private var variants = ""
    @State private var error: String?
    @State private var hovering = false
    @FocusState private var termFocused: Bool

    var body: some View {
        Group {
            if isEditing { editor } else { display }
        }
        .padding(.vertical, 4)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Correct spelling", text: $term)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .focused($termFocused)
                    .onSubmit(save)
                TextField("Heard as, separate with commas", text: $variants)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Cancel", action: onCancel)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let warning = DictionarySettingsView.riskWarning(variants, store: viewModel.vocabulary, excluding: entry.id) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onExitCommand(perform: onCancel)
        .onAppear {
            term = entry.term
            variants = entry.variants.joined(separator: ", ")
            termFocused = true
        }
    }

    private var display: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(entry.term)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 200, alignment: .leading)
                .lineLimit(1)
                .help(entry.term)
            if entry.variants.isEmpty {
                Text("Recognition hint only")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    ForEach(entry.variants.prefix(4), id: \.self) { variant in
                        Text(variant)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                    if entry.variants.count > 4 {
                        Text("+\(entry.variants.count - 4) more")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .help("Heard as: " + entry.variants.joined(separator: ", "))
            }
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .accessibilityLabel("Delete \(entry.term)")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Edit", action: onEdit)
            Button("Delete", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Edit", onEdit)
        .accessibilityAction(named: "Delete", onDelete)
    }

    private func save() {
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var updated = entry
        updated.term = term
        updated.variants = variants.split(separator: ",").map(String.init)
        do {
            try onSave(updated)
            error = nil
        } catch VocabularyStore.UpdateError.duplicate(let existing) {
            error = "\u{201C}\(existing)\u{201D} is already in your dictionary."
        } catch {
            self.error = "The word can't be empty."
        }
    }
}
