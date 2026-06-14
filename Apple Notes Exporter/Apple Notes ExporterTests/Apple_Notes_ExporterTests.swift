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

}
