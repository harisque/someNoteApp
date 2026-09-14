import SwiftUI
import DocumentAssistant

/// Main-window editor for a Markdown note. Notes are `Document`s with
/// `isNote == true`; saving calls `assistant.updateNote`, which rewrites the
/// catalog entry and rebuilds its index chunks so Ask stays up to date.
///
/// Two modes: a rendered Preview (via `MarkdownAnswerView`) and a raw-Markdown
/// Edit mode (title field + `TextEditor`). Drafts are held in `@State` and only
/// persisted on an explicit Save or when leaving with unsaved changes, so there
/// is no reindex per keystroke.
struct NoteEditorView: View {
    let document: Document
    let assistant: DocumentAssistant
    var onChanged: () -> Void
    var onDelete: () -> Void

    @State private var draftTitle: String
    @State private var draftText: String
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var isDirty = false
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?
    /// Fact Check (personal notes only): the preview's current text selection and the
    /// pending request. The preview renders in a selectable text view so selection can
    /// be observed and the native call-out suppressed, matching the document readers.
    @State private var selectedText: String?
    @State private var factCheckRequest: FactCheckRequest?

    init(document: Document,
         assistant: DocumentAssistant,
         onChanged: @escaping () -> Void,
         onDelete: @escaping () -> Void) {
        self.document = document
        self.assistant = assistant
        self.onChanged = onChanged
        self.onDelete = onDelete
        _draftTitle = State(initialValue: document.name)
        _draftText = State(initialValue: document.text)
    }

    private var trimmedTitle: String {
        let t = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled note" : t
    }

    /// Fact Check is offered only on personal notes.
    private var allowFactCheck: Bool { document.category == .personal }

    private func requestFactCheck(_ text: String) {
        guard allowFactCheck else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        factCheckRequest = FactCheckRequest(text: trimmed)
        selectedText = nil
    }

    @ViewBuilder private var factCheckButton: some View {
        if allowFactCheck, let text = selectedText, !text.isEmpty {
            FactCheckButton { requestFactCheck(text) }
        }
    }

    var body: some View {
        Group {
            if isEditing { editor } else { preview }
        }
        .navigationTitle(draftTitle.isEmpty ? "Note" : draftTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(item: $factCheckRequest) { request in
            FactCheckSheet(claim: request.text, assistant: assistant)
        }
        .alert("Delete note?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { confirmDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes \"\(trimmedTitle)\" from your notes and search index.")
        }
        .alert("Couldn't save note", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear { if isDirty { Task { await persist(silent: true) } } }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    // MARK: - Modes

    @ViewBuilder private var preview: some View {
        if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(trimmedTitle)
                        .font(.title2.weight(.bold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Nothing to preview yet. Tap Edit to write your note.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            // Rendered in a selectable text view (rather than the SwiftUI markdown
            // view) so the selection can be observed for Fact Check and the native
            // call-out suppressed, matching the document readers.
            ScrollableTextReader(
                text: "# \(trimmedTitle)\n\n\(draftText)",
                rendersMarkdown: true,
                onSelectionChange: { selectedText = $0 }
            )
            .overlay(alignment: .bottom) { factCheckButton }
            .animation(.easeInOut(duration: 0.15), value: selectedText)
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            TextField("Note title", text: $draftTitle)
                .font(.title3.weight(.semibold))
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.vertical, 8)
            Divider()
            TextEditor(text: $draftText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .overlay(alignment: .topLeading) {
                    if draftText.isEmpty {
                        Text("Write your note in Markdown…")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
        .onChange(of: draftTitle) { _, _ in isDirty = true }
        .onChange(of: draftText) { _, _ in isDirty = true }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                selectedText = nil
                withAnimation { isEditing.toggle() }
            } label: {
                Label(isEditing ? "Preview" : "Edit",
                      systemImage: isEditing ? "eye" : "square.and.pencil")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isSaving {
                ProgressView()
            } else {
                Button("Save") { Task { await persist(silent: false) } }
                    .disabled(!isDirty)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Actions

    private func persist(silent: Bool) async {
        guard isDirty else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await assistant.updateNote(id: document.id, title: trimmedTitle, text: draftText)
            isDirty = false
            errorMessage = nil
            if !silent { onChanged() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func confirmDelete() {
        Task {
            do {
                isDirty = false
                try await assistant.deleteDocument(id: document.id)
                onDelete()
            } catch {
                isDirty = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
