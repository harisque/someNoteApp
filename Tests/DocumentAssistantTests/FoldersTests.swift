import Foundation
import Testing
@testable import DocumentAssistant

private struct EchoModel: LanguageModel {
    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(prompt)
            continuation.finish()
        }
    }
}

@Suite("Categories and folders")
struct FoldersTests {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoldersTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAssistant() throws -> (DocumentAssistant, URL) {
        let root = try workspace()
        let assistant = DocumentAssistant(model: EchoModel(), store: root.appendingPathComponent("catalog.json"))
        return (assistant, root)
    }

    @discardableResult
    private func writeText(_ name: String, in root: URL, body: String = "keyword body") throws -> URL {
        let url = root.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Model + migration

    @Test("New documents default to the personal category")
    func defaultsToPersonal() {
        let doc = Document(name: "File.txt", text: "body")
        #expect(doc.category == .personal)
        #expect(doc.folderID == nil)
        #expect(doc.isNote == false)
    }

    @Test("Legacy and interim catalogs migrate into the two-category model")
    func legacyMigration() throws {
        let id = UUID().uuidString
        // Legacy: only an isNote bool, no category -> personal + note.
        let noteJSON = #"{"id":"\#(id)","name":"Old note","text":"body","isNote":true}"#.data(using: .utf8)!
        let note = try JSONDecoder().decode(Document.self, from: noteJSON)
        #expect(note.category == .personal)
        #expect(note.isNote == true)
        #expect(note.folderID == nil)

        // Interim shipped build: category "aiNote" -> personal + note.
        let interimJSON = #"{"id":"\#(id)","name":"Interim","text":"body","category":"aiNote"}"#.data(using: .utf8)!
        let interim = try JSONDecoder().decode(Document.self, from: interimJSON)
        #expect(interim.category == .personal)
        #expect(interim.isNote == true)

        // A modern payload with an explicit category wins.
        let modernJSON = #"{"id":"\#(id)","name":"C","text":"body","category":"confidential"}"#.data(using: .utf8)!
        let modern = try JSONDecoder().decode(Document.self, from: modernJSON)
        #expect(modern.category == .confidential)
        #expect(modern.isNote == false)

        // A legacy folder with an "aiNote" category decodes (to personal) without
        // failing the whole array.
        let fid = UUID().uuidString
        let foldersJSON = #"[{"id":"\#(fid)","name":"Old","category":"aiNote"}]"#.data(using: .utf8)!
        let folders = try JSONDecoder().decode([Folder].self, from: foldersJSON)
        #expect(folders.count == 1)
        #expect(folders[0].category == .personal)
        #expect(folders[0].isSystem == false)
    }

    // MARK: - System folders + note routing

    @Test("Both permanent AI Notes system folders exist after init")
    func systemFoldersSeeded() async throws {
        let (assistant, root) = try makeAssistant()
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = await assistant.folders
        #expect(folders.first { $0.id == DocumentAssistant.personalAINotesFolderID }?.isSystem == true)
        #expect(folders.first { $0.id == DocumentAssistant.personalAINotesFolderID }?.category == .personal)
        #expect(folders.first { $0.id == DocumentAssistant.confidentialAINotesFolderID }?.isSystem == true)
        #expect(folders.first { $0.id == DocumentAssistant.confidentialAINotesFolderID }?.category == .confidential)
    }

    @Test("createNote files into the right category's AI Notes folder")
    func createNoteRouting() async throws {
        let (assistant, root) = try makeAssistant()
        defer { try? FileManager.default.removeItem(at: root) }

        let personalNote = try await assistant.createNote(title: "P", text: "body", category: .personal)
        let confidentialNote = try await assistant.createNote(title: "C", text: "body", category: .confidential)
        let docs = await assistant.documents
        let p = try #require(docs.first { $0.id == personalNote })
        let c = try #require(docs.first { $0.id == confidentialNote })
        #expect(p.isNote && p.category == .personal && p.folderID == DocumentAssistant.personalAINotesFolderID)
        #expect(c.isNote && c.category == .confidential && c.folderID == DocumentAssistant.confidentialAINotesFolderID)
        #expect((await assistant.notes()).count == 2)
    }

    // MARK: - Folder CRUD

    @Test("Folders can be created in personal but not confidential")
    func folderCreationRejectsConfidential() async throws {
        let (assistant, root) = try makeAssistant()
        defer { try? FileManager.default.removeItem(at: root) }

        let personal = try await assistant.createFolder(name: "Work", category: .personal)
        let folders = await assistant.folders
        // Two system AI Notes folders plus the one user folder.
        #expect(folders.contains { $0.id == personal })
        #expect(folders.first { $0.id == personal }?.name == "Work")
        #expect(folders.first { $0.id == personal }?.isSystem == false)

        await #expect(throws: DocumentError.self) {
            try await assistant.createFolder(name: "Secret", category: .confidential)
        }
    }

    @Test("Renaming and deleting a user folder reassigns its documents to the root")
    func renameAndDeleteFolder() async throws {
        let (assistant, root) = try makeAssistant()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = try await assistant.createFolder(name: "Work", category: .personal)
        let file = try writeText("doc.txt", in: root)
        try await assistant.importDocument(url: file, category: .personal, folderID: folder)
        let docID = try #require((await assistant.documents).first?.id)
        #expect((await assistant.documents).first?.folderID == folder)

        try await assistant.renameFolder(id: folder, to: "Job")
        #expect((await assistant.folders).first { $0.id == folder }?.name == "Job")

        try await assistant.deleteFolder(id: folder)
        #expect(!(await assistant.folders).contains { $0.id == folder })
        // The document survives, moved back to the personal root.
        #expect((await assistant.documents).first?.id == docID)
        #expect((await assistant.documents).first?.folderID == nil)
    }

    @Test("System AI Notes folders cannot be renamed or deleted")
    func systemFolderProtected() async throws {
        let (assistant, root) = try makeAssistant()
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: DocumentError.self) {
            try await assistant.renameFolder(id: DocumentAssistant.personalAINotesFolderID, to: "Nope")
        }
        await #expect(throws: DocumentError.self) {
            try await assistant.deleteFolder(id: DocumentAssistant.confidentialAINotesFolderID)
        }
    }

    // MARK: - Move

    @Test("Documents move into a folder and back out; AI Notes rejects non-notes")
    func moveWithinCategory() async throws {
        let (assistant, root) = try makeAssistant()
        defer { try? FileManager.default.removeItem(at: root) }

        let personalFolder = try await assistant.createFolder(name: "Work", category: .personal)
        let file = try writeText("doc.txt", in: root)
        try await assistant.importDocument(url: file, category: .personal)
        let docID = try #require((await assistant.documents).first?.id)

        // Into a user folder, then back out to the personal root (regression).
        try await assistant.moveDocument(id: docID, toFolder: personalFolder)
        #expect((await assistant.documents).first?.folderID == personalFolder)
        try await assistant.moveDocument(id: docID, toFolder: nil)
        #expect((await assistant.documents).first?.folderID == nil)

        // Moving a non-note into the AI Notes system folder is rejected.
        await #expect(throws: DocumentError.self) {
            try await assistant.moveDocument(id: docID, toFolder: DocumentAssistant.personalAINotesFolderID)
        }
    }

    @Test("Notes cannot be moved")
    func notesNotMovable() async throws {
        let (assistant, root) = try makeAssistant()
        defer { try? FileManager.default.removeItem(at: root) }

        let noteID = try await assistant.createNote(title: "N", text: "body", category: .personal)
        await #expect(throws: DocumentError.self) {
            try await assistant.moveDocument(id: noteID, toFolder: nil)
        }
    }

    @Test("Cross-category moves are rejected")
    func crossCategoryMoveRejected() async throws {
        let (assistant, root) = try makeAssistant()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = try writeText("doc.txt", in: root)
        try await assistant.importDocument(url: file, category: .personal)
        let docID = try #require((await assistant.documents).first?.id)
        await #expect(throws: DocumentError.self) {
            try await assistant.moveDocument(id: docID, toFolder: DocumentAssistant.confidentialAINotesFolderID)
        }
    }

    // MARK: - Confidential read-only + seeding

    @Test("Confidential non-notes are read-only; confidential notes are deletable")
    func confidentialReadOnly() async throws {
        let (assistant, root) = try makeAssistant()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = try writeText("policy.txt", in: root, body: "confidential keyword")
        try await assistant.importDocument(url: file, category: .confidential)
        let docID = try #require((await assistant.documents).first?.id)

        await #expect(throws: DocumentError.self) { try await assistant.deleteDocument(id: docID) }
        await #expect(throws: DocumentError.self) { try await assistant.moveDocument(id: docID, toFolder: nil) }

        // A confidential note, by contrast, can be deleted.
        let noteID = try await assistant.createNote(title: "CN", text: "body", category: .confidential)
        try await assistant.deleteDocument(id: noteID)
        #expect(!(await assistant.documents).contains { $0.id == noteID })
        #expect((await assistant.documents).count == 1)
    }

    @Test("Bundled confidential seeding is idempotent across launches")
    func bundledSeedingIdempotent() async throws {
        let (assistant, root) = try makeAssistant()
        defer { try? FileManager.default.removeItem(at: root) }

        let bundleDir = root.appendingPathComponent("Confidential", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        try writeText("Policy.md", in: bundleDir, body: "official policy")
        try writeText("NDA.txt", in: bundleDir, body: "non disclosure")

        try await assistant.syncBundledConfidential(bundleFolderURL: bundleDir)
        #expect((await assistant.documents).filter { $0.category == .confidential }.count == 2)

        // Running again adds nothing new.
        try await assistant.syncBundledConfidential(bundleFolderURL: bundleDir)
        #expect((await assistant.documents).filter { $0.category == .confidential }.count == 2)
    }
}
