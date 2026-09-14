import Foundation

public struct OKFConcept: Hashable, Sendable {
    public let id: String
    public let type: String
    public let title: String
    public let metadata: [String: String]
    public let body: String
    public let fileURL: URL
}

/// Native producer and consumer for the OKF v0.2 Markdown/YAML bundle format.
public struct OKFBundle: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public func conceptID(for section: IndexedChunk) -> String {
        "sections/\(section.documentID.uuidString.lowercased())/\(section.location)"
    }

    public func write(
        documents: [Document], sections: [IndexedChunk],
        dataLinks: [DataLink] = [], summaries: [UUID: String] = [:]
    ) throws {
        let fm = FileManager.default
        let parent = root.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".OKFBundle-\(UUID().uuidString)", isDirectory: true)
        let docsDir = staging.appendingPathComponent("documents", isDirectory: true)
        let sectionsDir = staging.appendingPathComponent("sections", isDirectory: true)
        let dataLinksDir = staging.appendingPathComponent("datalinks", isDirectory: true)
        try fm.createDirectory(at: docsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: sectionsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: dataLinksDir, withIntermediateDirectories: true)

        do {
            var documentLinks: [String] = []
            for document in documents {
                let slug = document.id.uuidString.lowercased()
                let relative = "documents/\(slug).md"
                let content = frontmatter([
                    ("type", "Document"), ("title", document.name),
                    ("resource", relative), ("status", "stable"),
                    ("source_file", document.name),
                    ("category", document.category.rawValue),
                    ("isNote", document.isNote ? "true" : "false")
                ]) + "\n# \(document.name)\n\n" + document.text + "\n"
                try content.write(
                    to: docsDir.appendingPathComponent(slug).appendingPathExtension("md"),
                    atomically: true, encoding: .utf8
                )
                documentLinks.append("- [\(escapeMarkdown(document.name))](\(relative))")
            }

            var sectionLinks: [String] = []
            for section in sections {
                let documentSlug = section.documentID.uuidString.lowercased()
                let directory = sectionsDir.appendingPathComponent(documentSlug, isDirectory: true)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                let conceptID = conceptID(for: section)
                var fields: [(String, String)] = [
                    ("type", "Document Section"),
                    ("title", "\(section.document) at \(section.location)"),
                    ("resource", conceptID + ".md"),
                    ("status", "stable"),
                    ("document_id", section.documentID.uuidString),
                    ("location", String(section.location)),
                    ("sources", "[{ resource: ../../documents/\(documentSlug).md, title: \(yaml(section.document)) }]")
                ]
                if let page = section.page { fields.append(("page", String(page))) }
                let content = frontmatter(fields) + "\n" + section.text + "\n"
                try content.write(
                    to: directory.appendingPathComponent("\(section.location).md"),
                    atomically: true, encoding: .utf8
                )
                let label = section.page.map { "\(section.document), page \($0)" }
                    ?? "\(section.document), offset \(section.location)"
                sectionLinks.append("- [\(escapeMarkdown(label))](\(conceptID).md)")
            }

            // Emit one compact concept per Data Link so Ask can surface and cite live
            // structured data. The body is the pre-computed summary text (bounded prose,
            // never the raw series); `last_refreshed` is stamped when a snapshot exists.
            var dataLinkLinks: [String] = []
            // Local formatter: ISO8601DateFormatter is a reference type; keeping it local
            // avoids shared mutable state under Swift 6 strict concurrency.
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            for link in dataLinks {
                let slug = link.id.uuidString.lowercased()
                let relative = "datalinks/\(slug).md"
                var fields: [(String, String)] = [
                    ("type", "Data Link"), ("title", link.name),
                    ("resource", relative), ("status", "live"),
                    ("symbol", link.symbol), ("source", link.sourceID),
                    ("category", link.category.rawValue),
                    ("data_link_id", link.id.uuidString)
                ]
                if let last = link.lastRefreshedAt {
                    fields.append(("last_refreshed", iso.string(from: last)))
                }
                let body = summaries[link.id] ?? link.scopeDescription
                let content = frontmatter(fields) + "\n# \(link.name) (\(link.symbol))\n\n" + body + "\n"
                try content.write(
                    to: dataLinksDir.appendingPathComponent(slug).appendingPathExtension("md"),
                    atomically: true, encoding: .utf8
                )
                dataLinkLinks.append("- [\(escapeMarkdown(link.name)) (\(escapeMarkdown(link.symbol)))](\(relative))")
            }

            let index = frontmatter([
                ("type", "Index"), ("title", "Document Assistant Knowledge Bundle")
            ]) + "\n# Documents\n\n" + documentLinks.joined(separator: "\n")
                + "\n\n# Sections\n\n" + sectionLinks.joined(separator: "\n")
                + (dataLinkLinks.isEmpty ? "" : "\n\n# Data Links\n\n" + dataLinkLinks.joined(separator: "\n"))
                + "\n"
            try index.write(
                to: staging.appendingPathComponent("index.md"),
                atomically: true, encoding: .utf8
            )

            let backup = parent.appendingPathComponent(".OKFBundle-previous", isDirectory: true)
            if fm.fileExists(atPath: backup.path) {
                if !fm.fileExists(atPath: root.path) { try fm.moveItem(at: backup, to: root) }
                else { try fm.removeItem(at: backup) }
            }
            if fm.fileExists(atPath: root.path) { try fm.moveItem(at: root, to: backup) }
            do { try fm.moveItem(at: staging, to: root) }
            catch {
                if fm.fileExists(atPath: backup.path) { try fm.moveItem(at: backup, to: root) }
                throw error
            }
            // Keep the previous complete bundle until the next successful write.
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    public func readConcept(id: String) throws -> OKFConcept {
        guard !id.contains(".."), !id.hasPrefix("/") else { throw OKFError.invalidConceptID }
        let file = root.appendingPathComponent(id).appendingPathExtension("md")
        return try parse(String(contentsOf: file, encoding: .utf8), fileURL: file, fallbackID: id)
    }

    public func readAllConcepts() throws -> [OKFConcept] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        var concepts: [OKFConcept] = []
        for case let file as URL in enumerator
        where file.pathExtension.lowercased() == "md" && file.lastPathComponent != "index.md" {
            let relative = file.deletingPathExtension().path
                .replacingOccurrences(of: root.path + "/", with: "")
            concepts.append(try parse(
                String(contentsOf: file, encoding: .utf8),
                fileURL: file, fallbackID: relative
            ))
        }
        return concepts
    }

    private func parse(_ text: String, fileURL: URL, fallbackID: String) throws -> OKFConcept {
        guard text.hasPrefix("---\n"),
              let end = text.range(
                of: "\n---\n",
                range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex
              ) else { throw OKFError.invalidFrontmatter }
        let header = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]
        var metadata: [String: String] = [:]
        for line in header.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            metadata[key] = unquote(raw)
        }
        guard let type = metadata["type"], !type.isEmpty else { throw OKFError.missingType }
        return OKFConcept(
            id: fallbackID, type: type,
            title: metadata["title"] ?? fileURL.deletingPathExtension().lastPathComponent,
            metadata: metadata, body: String(text[end.upperBound...]), fileURL: fileURL
        )
    }

    private func frontmatter(_ fields: [(String, String)]) -> String {
        "---\n" + fields.map { key, value in
            let raw = value.hasPrefix("[") || Int(value) != nil
                || ["true", "false", "null"].contains(value) ? value : yaml(value)
            return "\(key): \(raw)"
        }.joined(separator: "\n") + "\n---\n"
    }

    private func yaml(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private func unquote(_ value: String) -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private func escapeMarkdown(_ value: String) -> String {
        value.replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }
}

public enum OKFError: LocalizedError {
    case invalidConceptID, invalidFrontmatter, missingType
    public var errorDescription: String? {
        switch self {
        case .invalidConceptID: return "Invalid OKF concept identifier."
        case .invalidFrontmatter: return "The OKF document has invalid YAML frontmatter."
        case .missingType: return "The OKF document is missing its required type field."
        }
    }
}
