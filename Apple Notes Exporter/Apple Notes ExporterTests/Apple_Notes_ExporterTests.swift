//
//  Apple_Notes_ExporterTests.swift
//  Apple Notes Exporter
//
//  Copyright (C) 2026 Konstantin Zaremski
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import XCTest
import SQLite3
import CryptoKit
@testable import Apple_Notes_Exporter

final class Apple_Notes_ExporterTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // Any test you write for XCTest can be annotated as throws and async.
        // Mark your test throws to produce an unexpected failure when your test encounters an uncaught error.
        // Mark your test async to allow awaiting for asynchronous code to complete. Check the results with assertions afterwards.
    }

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }

    func testSanitizedFileNamePreservesVisualSlash() throws {
        let note = makeNote(
            title: "[Day 2/7] Your Glasses, A 100 Billion Dollar Lie"
        )

        XCTAssertEqual(note.sanitizedFileName, "[Day 2\u{2215}7] Your Glasses, A 100 Billion Dollar Lie")
    }

    func testNoteContentFingerprintChangesWhenNoteMoves() throws {
        let original = makeNote(
            id: "note-1",
            title: "GitHub Reset",
            plaintext: "Same body",
            folderId: "endmyopia",
            accountId: "icloud"
        )
        let movedFolder = makeNote(
            id: "note-1",
            title: "GitHub Reset",
            plaintext: "Same body",
            folderId: "tech",
            accountId: "icloud"
        )
        let movedAccount = makeNote(
            id: "note-1",
            title: "GitHub Reset",
            plaintext: "Same body",
            folderId: "endmyopia",
            accountId: "on-my-mac"
        )

        XCTAssertNotEqual(
            NoteContentFingerprint.value(for: original),
            NoteContentFingerprint.value(for: movedFolder)
        )
        XCTAssertNotEqual(
            NoteContentFingerprint.value(for: original),
            NoteContentFingerprint.value(for: movedAccount)
        )

        var manifest = SyncManifest.empty()
        manifest.recordExport(
            noteId: original.id,
            modificationDate: original.modificationDate,
            exportedPath: "iCloud/Endmyopia/GitHub Reset.md",
            contentFingerprint: NoteContentFingerprint.value(for: original)
        )

        let notesNeedingExport = manifest.notesNeedingExport(
            from: [movedFolder],
            contentFingerprint: { NoteContentFingerprint.value(for: $0) }
        )

        XCTAssertEqual(notesNeedingExport.map(\.id), ["note-1"])
    }

    func testPasswordProtectedNoteReportIncludesLocationAndUnreadableFallbacks() throws {
        let locked = makeNote(
            id: "locked-1",
            title: "Locked Planning Note",
            plaintext: "Private locked body",
            folderId: "private-folder",
            accountId: "icloud",
            isPasswordProtected: true
        )
        let unreadable = makeNote(
            id: "blank-1",
            sourceFingerprint: "encrypted-or-unreadable-bytes",
            title: NotesNote.fallbackTitle(for: "blank-1"),
            plaintext: "",
            folderId: "archive-folder",
            accountId: "icloud",
            isPasswordProtected: false
        )
        let unlocked = makeNote(
            id: "unlocked-1",
            title: "Regular Note",
            plaintext: "Regular body",
            folderId: "private-folder",
            accountId: "icloud"
        )

        let report = PasswordProtectedNoteReport.make(
            for: [unlocked, locked, unreadable],
            accountNames: ["icloud": "iCloud"],
            folderPaths: [
                "archive-folder": "Archive/Locked",
                "private-folder": "Personal"
            ]
        )

        XCTAssertEqual(report.count, 2)
        XCTAssertTrue(report.hasNotes)
        XCTAssertTrue(report.summaries.contains("Locked Planning Note - iCloud/Personal (locked)"))
        XCTAssertTrue(report.summaries.contains("Note blank-1 - iCloud/Archive/Locked (unreadable/possibly locked)"))
        XCTAssertFalse(report.summary.contains("Private locked body"))
        XCTAssertFalse(report.summary.contains("Regular body"))
        XCTAssertFalse(report.summaries.joined(separator: "\n").contains("Private locked body"))
        XCTAssertFalse(report.summaries.joined(separator: "\n").contains("Regular body"))
    }

    func testLockedNotePlaceholderUsesTitleAndDoesNotExposeBody() throws {
        let note = makeNote(
            id: "locked-1",
            title: "Locked <Planning> Note",
            plaintext: "Private locked body",
            isPasswordProtected: true
        )

        let html = try XCTUnwrap(LockedNotePlaceholder.html(for: note))

        XCTAssertTrue(html.contains("Locked &lt;Planning&gt; Note"))
        XCTAssertTrue(html.contains("This note is locked in Apple Notes."))
        XCTAssertTrue(html.contains("body is unavailable until the note is unlocked"))
        XCTAssertFalse(html.contains("Private locked body"))
        XCTAssertFalse(html.contains("<Planning>"))
    }

    func testUnreadableFallbackNotePlaceholderUsesFallbackTitleAndDoesNotExposeBody() throws {
        let note = makeNote(
            id: "blank-1",
            sourceFingerprint: "encrypted-or-unreadable-bytes",
            title: NotesNote.fallbackTitle(for: "blank-1"),
            plaintext: "",
            isPasswordProtected: false
        )

        let html = try XCTUnwrap(LockedNotePlaceholder.html(for: note))

        XCTAssertTrue(html.contains("Note blank-1"))
        XCTAssertTrue(html.contains("locked or unreadable in Apple Notes"))
        XCTAssertTrue(html.contains("available title and metadata were exported"))
        XCTAssertTrue(html.contains("until the note is unlocked or readable in Apple Notes"))
    }

    func testLockedNoteMarkdownPlaceholderIsObsidianReadableAndDoesNotExposeBody() throws {
        let note = makeNote(
            id: "locked-1",
            title: "Locked Planning Note",
            plaintext: "Private locked body",
            isPasswordProtected: true
        )

        let markdown = try XCTUnwrap(LockedNotePlaceholder.markdown(for: note))

        XCTAssertEqual(
            markdown,
            """
            # Locked Planning Note

            Locked Planning Note is a locked note from Apple Notes. Its body content is unavailable until the note is unlocked in Apple Notes.
            """
        )
        XCTAssertFalse(markdown.contains("Private locked body"))
        XCTAssertFalse(markdown.contains("body {"))
        XCTAssertFalse(markdown.contains("pre {"))
        XCTAssertFalse(markdown.contains("```"))
    }

    func testUnreadableFallbackMarkdownPlaceholderUsesFallbackTitle() throws {
        let note = makeNote(
            id: "212",
            sourceFingerprint: "encrypted-or-unreadable-bytes",
            title: NotesNote.fallbackTitle(for: "212"),
            plaintext: "",
            isPasswordProtected: false
        )

        let markdown = try XCTUnwrap(LockedNotePlaceholder.markdown(for: note))

        XCTAssertEqual(
            markdown,
            """
            # Note 212

            Note 212 is a locked or unreadable note from Apple Notes. Its body content is unavailable until the note is unlocked or readable in Apple Notes.
            """
        )
        XCTAssertFalse(markdown.contains("body {"))
        XCTAssertFalse(markdown.contains("pre {"))
        XCTAssertFalse(markdown.contains("```"))
    }

    func testUnreadableFallbackFingerprintForcesPlaceholderMigration() throws {
        let note = makeNote(
            id: "212",
            sourceFingerprint: "encrypted-or-unreadable-bytes",
            title: NotesNote.fallbackTitle(for: "212"),
            plaintext: "",
            isPasswordProtected: false
        )

        XCTAssertNotEqual(
            NoteContentFingerprint.value(for: note),
            legacyContentFingerprintWithoutLockedPlaceholderVersion(for: note)
        )
    }

    func testRegularNoteFingerprintDoesNotChangeForLockedPlaceholderMigration() throws {
        let note = makeNote(
            id: "regular-1",
            title: "Regular Note",
            plaintext: "Regular body",
            isPasswordProtected: false
        )

        XCTAssertEqual(
            NoteContentFingerprint.value(for: note),
            legacyContentFingerprintWithoutLockedPlaceholderVersion(for: note)
        )
    }

    func testManifestAcceptsEmptyPlaceholderVersionFieldFingerprintForRegularNotes() throws {
        let note = makeNote(
            id: "regular-1",
            title: "Regular Note",
            plaintext: "Regular body",
            isPasswordProtected: false
        )

        var manifest = SyncManifest.empty()
        manifest.recordExport(
            noteId: note.id,
            modificationDate: note.modificationDate,
            exportedPath: "iCloud/Regular Note.md",
            contentFingerprint: emptyPlaceholderVersionFieldContentFingerprint(for: note)
        )

        let notesNeedingExport = manifest.notesNeedingExport(
            from: [note],
            contentFingerprint: { NoteContentFingerprint.value(for: $0) },
            acceptedContentFingerprints: { NoteContentFingerprint.acceptedValues(for: $0) }
        )

        XCTAssertEqual(notesNeedingExport.map(\.id), [])
    }

    func testUnlockedNoteDoesNotUseLockedNotePlaceholder() throws {
        let note = makeNote(
            id: "unlocked-1",
            title: "Regular Note",
            plaintext: "Regular body",
            isPasswordProtected: false
        )

        XCTAssertNil(LockedNotePlaceholder.html(for: note))
        XCTAssertNil(LockedNotePlaceholder.markdown(for: note))
    }

    @MainActor
    func testStaleManifestCleanupDoesNotDeleteOutsideOutputRoot() throws {
        let fileManager = FileManager.default
        let baseURL = fileManager.temporaryDirectory
            .appendingPathComponent("AppleNotesExporterCleanupGuard-\(UUID().uuidString)", isDirectory: true)
        let outputRootURL = baseURL.appendingPathComponent("Export", isDirectory: true)
        let insideFolderURL = outputRootURL.appendingPathComponent("iCloud", isDirectory: true)
        let insideStaleURL = insideFolderURL.appendingPathComponent("Stale.md")
        let outsideFileURL = baseURL.appendingPathComponent("outside.md")
        let outsideAttachmentURL = baseURL.appendingPathComponent("outside-attachment.jpg")

        try fileManager.createDirectory(at: insideFolderURL, withIntermediateDirectories: true)
        try "stale".write(to: insideStaleURL, atomically: true, encoding: .utf8)
        try "outside".write(to: outsideFileURL, atomically: true, encoding: .utf8)
        try "outside attachment".write(to: outsideAttachmentURL, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: baseURL) }

        var manifest = SyncManifest.empty()
        manifest.recordExport(
            noteId: "stale-inside-note",
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            exportedPath: "iCloud/Stale.md",
            attachmentPaths: ["../outside-attachment.jpg"]
        )
        manifest.recordExport(
            noteId: "stale-traversal-note",
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            exportedPath: "../outside.md"
        )

        let removedCount = try ExportViewModel().removeManifestEntriesNotInCurrentExportSet(
            from: &manifest,
            currentNoteIDs: [],
            outputRootURL: outputRootURL
        )

        XCTAssertEqual(removedCount, 2)
        XCTAssertFalse(fileManager.fileExists(atPath: insideStaleURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: outsideFileURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: outsideAttachmentURL.path))
        XCTAssertTrue(manifest.notes.isEmpty)
    }

    @MainActor
    func testStaleManifestCleanupPrunesDeletedNoteArtifactsAndPreservesCurrentOnes() throws {
        let fileManager = FileManager.default
        let baseURL = fileManager.temporaryDirectory
            .appendingPathComponent("AppleNotesExporterDeletedNotePrune-\(UUID().uuidString)", isDirectory: true)
        let outputRootURL = baseURL.appendingPathComponent("Export", isDirectory: true)
        let folderURL = outputRootURL.appendingPathComponent("iCloud", isDirectory: true)
        let deletedFileURL = folderURL.appendingPathComponent("Deleted.md")
        let currentFileURL = folderURL.appendingPathComponent("Current.md")
        let deletedAttachmentURL = folderURL
            .appendingPathComponent("Deleted (Attachments)", isDirectory: true)
            .appendingPathComponent("deleted.jpg")
        let currentAttachmentURL = folderURL
            .appendingPathComponent("Current (Attachments)", isDirectory: true)
            .appendingPathComponent("current.jpg")

        try fileManager.createDirectory(at: deletedAttachmentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: currentAttachmentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "deleted".write(to: deletedFileURL, atomically: true, encoding: .utf8)
        try "current".write(to: currentFileURL, atomically: true, encoding: .utf8)
        try "deleted attachment".write(to: deletedAttachmentURL, atomically: true, encoding: .utf8)
        try "current attachment".write(to: currentAttachmentURL, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: baseURL) }

        var manifest = SyncManifest.empty()
        manifest.recordExport(
            noteId: "current-note",
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            exportedPath: "iCloud/Current.md",
            attachmentPaths: ["iCloud/Current (Attachments)/current.jpg"]
        )
        manifest.recordExport(
            noteId: "deleted-note",
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            exportedPath: "iCloud/Deleted.md",
            attachmentPaths: ["iCloud/Deleted (Attachments)/deleted.jpg"]
        )

        let removedCount = try ExportViewModel().removeManifestEntriesNotInCurrentExportSet(
            from: &manifest,
            currentNoteIDs: ["current-note"],
            outputRootURL: outputRootURL
        )

        XCTAssertEqual(removedCount, 1)
        XCTAssertFalse(fileManager.fileExists(atPath: deletedFileURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: deletedAttachmentURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: deletedAttachmentURL.deletingLastPathComponent().path))
        XCTAssertTrue(fileManager.fileExists(atPath: currentFileURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: currentAttachmentURL.path))
        XCTAssertEqual(Set(manifest.notes.keys), ["current-note"])
    }

    @MainActor
    func testRecentlyDeletedFolderChainIsExcluded() throws {
        let folderLookup: [String: NotesFolder] = [
            "root": NotesFolder(id: "root", name: "Notes", parentId: nil, accountId: "icloud"),
            "active": NotesFolder(id: "active", name: "Projects", parentId: "root", accountId: "icloud"),
            "deleted": NotesFolder(id: "deleted", name: " Recently Deleted ", parentId: "root", accountId: "icloud"),
            "deleted-child": NotesFolder(id: "deleted-child", name: "Nested", parentId: "deleted", accountId: "icloud"),
            "loop-a": NotesFolder(id: "loop-a", name: "Loop A", parentId: "loop-b", accountId: "icloud"),
            "loop-b": NotesFolder(id: "loop-b", name: "Loop B", parentId: "loop-a", accountId: "icloud")
        ]

        let viewModel = ExportViewModel()

        XCTAssertFalse(viewModel.isInRecentlyDeleted(folderId: "active", folderLookup: folderLookup))
        XCTAssertTrue(viewModel.isInRecentlyDeleted(folderId: "deleted", folderLookup: folderLookup))
        XCTAssertTrue(viewModel.isInRecentlyDeleted(folderId: "deleted-child", folderLookup: folderLookup))
        XCTAssertFalse(viewModel.isInRecentlyDeleted(folderId: "missing", folderLookup: folderLookup))
        XCTAssertFalse(viewModel.isInRecentlyDeleted(folderId: "loop-a", folderLookup: folderLookup))
    }

    func testLooseImageSourceUsesExportedAttachmentPath() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let processor = HTMLAttachmentProcessor(database: db!)
        let attachment = NotesAttachment(
            id: "image-1",
            typeUTI: "public.jpeg",
            filename: "9430A7CC-CB05-4DFC-8A58-DAB90C8F24B0.jpg"
        )
        let html = #"<html><body><img src="Preventing The" alt="Preventing The"></body></html>"#

        let processed = processor.processHTML(
            html: html,
            attachments: [attachment],
            attachmentPaths: [
                "image-1": "Preventing The 'Bad' Plateau - The Frauenfeld Clinic (Attachments)/9430A7CC-CB05-4DFC-8A58-DAB90C8F24B0.jpg"
            ],
            embedImages: false,
            linkEmbeddedImages: false
        )

        XCTAssertTrue(processed.contains(#"src="Preventing The &#39;Bad&#39; Plateau - The Frauenfeld Clinic (Attachments)/9430A7CC-CB05-4DFC-8A58-DAB90C8F24B0.jpg""#))
    }

    func testBareObsidianImageEmbedUsesExportedAttachmentPath() throws {
        let attachment = NotesAttachment(
            id: "image-1",
            typeUTI: "public.jpeg",
            filename: "9430A7CC-CB05-4DFC-8A58-DAB90C8F24B0.jpg"
        )
        let markdown = """
        **Preventing The 'Bad' Plateau
        **![[Preventing The ]]
        """

        let repaired = MarkdownAttachmentRepair.repairBareObsidianImageEmbeds(
            in: markdown,
            attachments: [attachment],
            attachmentPaths: [
                "image-1": "Preventing The 'Bad' Plateau - The Frauenfeld Clinic (Attachments)/9430A7CC-CB05-4DFC-8A58-DAB90C8F24B0.jpg"
            ]
        )

        XCTAssertTrue(repaired.contains("![[Preventing The 'Bad' Plateau - The Frauenfeld Clinic (Attachments)/9430A7CC-CB05-4DFC-8A58-DAB90C8F24B0.jpg]]"))
        XCTAssertFalse(repaired.contains("![[Preventing The ]]"))
    }

    func testProcessedHTMLImageAttachmentBecomesObsidianEmbed() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let attachment = NotesAttachment(
            id: "image-1",
            typeUTI: "public.jpeg",
            filename: "9430A7CC-CB05-4DFC-8A58-DAB90C8F24B0.jpg"
        )
        let attachmentPath = "Preventing The 'Bad' Plateau - The Frauenfeld Clinic (Attachments)/9430A7CC-CB05-4DFC-8A58-DAB90C8F24B0.jpg"
        let rawHTML = #"<html><body><p>Before</p><img src="Preventing The" alt="Preventing The"><p>After</p></body></html>"#

        let processedHTML = HTMLAttachmentProcessor(database: db!).processHTML(
            html: rawHTML,
            attachments: [attachment],
            attachmentPaths: ["image-1": attachmentPath],
            embedImages: false,
            linkEmbeddedImages: false
        )
        let note = makeNote(
            title: "Preventing The 'Bad' Plateau - The Frauenfeld Clinic",
            htmlBody: processedHTML,
            attachments: [attachment]
        )
        let markdown = note.toMarkdown(flavor: .obsidian)
        let repairedMarkdown = MarkdownAttachmentRepair.repairBareObsidianImageEmbeds(
            in: markdown,
            attachments: [attachment],
            attachmentPaths: ["image-1": attachmentPath]
        )

        XCTAssertTrue(repairedMarkdown.contains("![[\(attachmentPath)]]"))
        XCTAssertFalse(repairedMarkdown.contains("![[Preventing The]]"))
        XCTAssertFalse(repairedMarkdown.contains(#"src="Preventing The""#))
    }

    func testAppleNotesLinkBecomesObsidianWikilink() throws {
        let target = NoteLinkTarget(
            markdownPath: "../Tech/Review Preview - The Frauenfeld Clinic.md",
            obsidianReference: "iCloud/Tech/Review Preview - The Frauenfeld Clinic",
            title: "Review Preview - The Frauenfeld Clinic"
        )
        let note = makeNote(
            htmlBody: """
            <html><body>
            <p>See <a href="applenotes://note/TARGET-NOTE-ID">Review Preview - The Frauenfeld Clinic</a>.</p>
            </body></html>
            """
        )

        let markdown = note.toMarkdown(
            flavor: .obsidian,
            noteLinkTargets: ["TARGET-NOTE-ID": target]
        )

        XCTAssertTrue(markdown.contains("[[iCloud/Tech/Review Preview - The Frauenfeld Clinic|Review Preview - The Frauenfeld Clinic]]"))
        XCTAssertFalse(markdown.contains("applenotes://note/TARGET-NOTE-ID"))
    }

    func testAppleNotesQueryIdentifierLinkUsesObsidianAlias() throws {
        let target = NoteLinkTarget(
            markdownPath: "../EndMyopia/Preventing The Bad Plateau.md",
            obsidianReference: "iCloud/EndMyopia/Preventing The Bad Plateau",
            title: "Preventing The Bad Plateau"
        )
        let note = makeNote(
            htmlBody: """
            <html><body>
            <p>Source: <a href="applenotes://show?identifier=x-coredata://ABCDEF-123456">plateau note</a></p>
            </body></html>
            """
        )

        let markdown = note.toMarkdown(
            flavor: .obsidian,
            noteLinkTargets: ["x-coredata://ABCDEF-123456": target]
        )

        XCTAssertTrue(markdown.contains("[[iCloud/EndMyopia/Preventing The Bad Plateau|plateau note]]"))
        XCTAssertFalse(markdown.contains("applenotes://show?identifier=x-coredata://ABCDEF-123456"))
    }

    private func makeNote(
        id: String = "note-1",
        identifier: String? = nil,
        sourceFingerprint: String? = nil,
        title: String = "Test Note",
        plaintext: String = "",
        htmlBody: String? = nil,
        creationDate: Date = Date(timeIntervalSince1970: 1_700_000_000),
        modificationDate: Date = Date(timeIntervalSince1970: 1_700_000_100),
        folderId: String = "folder-1",
        accountId: String = "account-1",
        attachments: [NotesAttachment] = [],
        isPasswordProtected: Bool = false
    ) -> NotesNote {
        NotesNote(
            id: id,
            identifier: identifier,
            sourceFingerprint: sourceFingerprint,
            title: title,
            plaintext: plaintext,
            htmlBody: htmlBody,
            creationDate: creationDate,
            modificationDate: modificationDate,
            folderId: folderId,
            accountId: accountId,
            attachments: attachments,
            isPasswordProtected: isPasswordProtected
        )
    }

    private func legacyContentFingerprintWithoutLockedPlaceholderVersion(for note: NotesNote) -> String {
        let attachmentSignature = note.attachments
            .map { "\($0.id)|\($0.typeUTI)|\($0.filename ?? "")" }
            .sorted()
            .joined(separator: "\n")
        let payload = [
            note.id,
            note.identifier ?? "",
            note.sourceFingerprint ?? "",
            note.accountId,
            note.folderId,
            note.title,
            note.plaintext,
            attachmentSignature,
            note.isPasswordProtected ? "locked" : "unlocked"
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func emptyPlaceholderVersionFieldContentFingerprint(for note: NotesNote) -> String {
        let attachmentSignature = note.attachments
            .map { "\($0.id)|\($0.typeUTI)|\($0.filename ?? "")" }
            .sorted()
            .joined(separator: "\n")
        let payload = [
            note.id,
            note.identifier ?? "",
            note.sourceFingerprint ?? "",
            note.accountId,
            note.folderId,
            note.title,
            note.plaintext,
            attachmentSignature,
            note.isPasswordProtected ? "locked" : "unlocked",
            note.appearsLockedOrUnreadable ? LockedNotePlaceholder.contentFingerprintVersion : ""
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

}
