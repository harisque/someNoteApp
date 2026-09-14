import Foundation

/// Note support. Notes are Markdown `Document`s (`isNote == true`) stored in the
/// same catalog and index as imported files, so retrieval/`answer` spans them
/// with no extra work. Creating or editing a note rebuilds its index chunks and
/// persists, keeping Ask up to date.
@available(macOS 10.15, iOS 13.0, *)
extension DocumentAssistant {
    /// All note documents (`isNote == true`), in insertion order. Notes live in
    /// either category's permanent AI Notes folder.
    public func notes() async -> [Document] {
        documents.filter { $0.isNote }
    }

    /// Creates a new Markdown note in `category`'s permanent AI Notes folder,
    /// indexes it, persists, and returns its id. A note saved from an answer is
    /// routed to Confidential when the answer's scope touched any Confidential doc,
    /// otherwise Personal.
    @discardableResult
    public func createNote(title: String, text: String, category: DocumentCategory = .personal) async throws -> UUID {
        var note = Document(name: title, text: text, category: category, folderID: Self.aiNotesFolderID(for: category), isNote: true)
        note.indexedAt = Date()
        documents.append(note)
        try await rebuildIndex(for: note)
        try persist()
        return note.id
    }

    /// Updates a note's title/body, then re-indexes and persists.
    public func updateNote(id: UUID, title: String, text: String) async throws {
        guard let idx = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[idx].name = title
        documents[idx].text = text
        documents[idx].indexedAt = Date()
        try await rebuildIndex(for: documents[idx])
        try persist()
    }

    /// Generates a concise note title from a question. Tries a short on-device
    /// model call first; on empty, slow, or failing generation it falls back to a
    /// deterministic cleanup. Never throws, so "Save to Note" always succeeds.
    public func generateNoteTitle(from question: String) async -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Saved note" }
        if let modelTitle = await modelTitle(for: trimmed) { return modelTitle }
        return Self.heuristicTitle(trimmed)
    }

    /// Asks the model for a very short title, bounded by length and elapsed time
    /// so a slow or verbose generation cannot stall saving. Returns nil on any
    /// failure or empty result, signaling the caller to use the heuristic.
    private func modelTitle(for question: String) async -> String? {
        let prompt = """
        Write a short note title for this question.
        Rules: at most 6 words, title case, no quotes, no trailing punctuation, output only the title.
        Question: \(question)
        Title:
        """
        var out = ""
        let start = Date()
        do {
            for try await token in model.stream(prompt: prompt) {
                try Task.checkCancellation()
                out += token
                if out.count >= 80 || out.contains("\n") { break }
                if Date().timeIntervalSince(start) > 10 { break }
            }
        } catch {
            return nil
        }
        return Self.cleanTitle(out)
    }

    /// Normalizes raw model output into a title: first line only, strip quotes and
    /// a leading "Title:" echo, drop trailing punctuation, collapse whitespace,
    /// and truncate. Returns nil when nothing usable remains.
    static func cleanTitle(_ raw: String) -> String? {
        let firstLine = raw.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        var t = firstLine.trimmingCharacters(in: .whitespaces)
        for prefix in ["Title:", "title:", "Title", "title"] {
            if t.hasPrefix(prefix) {
                t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " :"))
            }
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: ".?!。,，;；: "))
        t = t.split(separator: " ").joined(separator: " ")
        guard !t.isEmpty else { return nil }
        return smartTruncate(t, limit: 60)
    }

    /// Deterministic fallback: take the first line, drop leading interrogative or
    /// filler phrases, strip trailing punctuation, collapse whitespace, capitalize
    /// the first letter, and truncate on a word boundary.
    public static func heuristicTitle(_ question: String) -> String {
        let firstLine = question.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? question
        var t = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let fillers = [
            "can you tell me", "could you tell me", "would you tell me",
            "tell me", "please", "i want to know", "i'd like to know",
            "what is", "what are", "what's", "whats", "what was", "what",
            "how do", "how does", "how is", "how are", "how",
            "why is", "why does", "why do", "why", "when does", "when",
            "where is", "where", "which", "who", "can you", "could you",
            "would you", "should i", "is there", "are there", "does", "do",
            "is", "are", "was", "were"
        ]
        var changed = true
        while changed {
            changed = false
            let lower = t.lowercased()
            for filler in fillers {
                guard lower.hasPrefix(filler) else { continue }
                let rest = t.dropFirst(filler.count)
                // Only strip when the filler is a whole word (followed by a space).
                if rest.first == " " {
                    t = rest.trimmingCharacters(in: .whitespaces)
                    changed = true
                    break
                }
            }
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: ".?!。,，;；: "))
        t = t.split(separator: " ").joined(separator: " ")
        guard !t.isEmpty else { return "Saved note" }
        t = t.prefix(1).uppercased() + t.dropFirst()
        return smartTruncate(t, limit: 48)
    }

    /// Truncates to `limit` characters, backing off to the last space so a word is
    /// not cut in half, and marks the cut with an ellipsis.
    private static func smartTruncate(_ s: String, limit: Int) -> String {
        guard s.count > limit else { return s }
        let cut = s.prefix(limit)
        if let lastSpace = cut.lastIndex(of: " ") {
            return String(cut[..<lastSpace]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return String(cut) + "…"
    }
}
