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
import Darwin
@testable import Apple_Notes_Exporter

private final class CollisionTestRepository: MockNotesRepository {
    var failingID: String?
    var blockedOutput: URL?

    override func generateHTML(forNoteId noteId: String) async throws -> String {
        if noteId == failingID, let blockedOutput {
            try FileManager.default.createDirectory(at: blockedOutput, withIntermediateDirectories: true)
        }
        if noteId == "source" {
            return "<p>Mock HTML for note source</p><a href=\"applenotes://note/first\">First</a><a href=\"applenotes://note/second\">Second</a>"
        }
        return try await super.generateHTML(forNoteId: noteId)
    }
}

final class Apple_Notes_ExporterTests: XCTestCase {

    @MainActor
    func testCLIStartupRunsOnceWithoutAWindow() async {
        let delegate = AppDelegate()
        let finished = expectation(description: "Headless launch")
        var calls = 0
        let args = ["exporter", "--export", "--output", "/tmp/synthetic-export", "--incremental", "--obsidian-links"]
        let run: @MainActor (LaunchExportOptions) async -> Void = { options in
            calls += 1
            XCTAssertTrue(options.incrementalSync)
            XCTAssertEqual(options.obsidianInternalLinksInMarkdown, true)
            XCTAssertEqual(options.outputURL.path, "/tmp/synthetic-export")
            XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
            finished.fulfill()
        }
        delegate.startLaunchExport(arguments: args, run: run)
        delegate.startLaunchExport(arguments: args, run: run)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testGUIStartupDoesNotScheduleCLIExport() async {
        let delegate = AppDelegate()
        delegate.startLaunchExport(arguments: ["exporter"]) { _ in
            XCTFail("Normal GUI launch must not export")
        }
        await Task.yield()
        XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    func testWriteBoundaryRejectsTraversalLinksAndAllowsNormalNewPaths() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("export")
        let outside = base.appendingPathComponent("outside")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        XCTAssertNoThrow(try ExportWriteBoundary.validate(root.appendingPathComponent("new/note.md"), root: root))
        XCTAssertThrowsError(try ExportWriteBoundary.validate(root.appendingPathComponent("../outside/note.md"), root: root))
        XCTAssertThrowsError(try ExportWriteBoundary.validate(base.appendingPathComponent("export-other/note.md"), root: root))
        for (name, destination) in [("escape", outside), ("dangling", outside.appendingPathComponent("absent")), ("inside", root)] {
            let link = root.appendingPathComponent(name)
            try fm.createSymbolicLink(at: link, withDestinationURL: destination)
            XCTAssertThrowsError(try ExportWriteBoundary.validate(link.appendingPathComponent("note.md"), root: root))
        }
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        let hardlink = root.appendingPathComponent("hardlink")
        try fm.linkItem(at: sentinel, to: hardlink)
        XCTAssertThrowsError(try ExportWriteBoundary.validate(hardlink, root: root))
        let linkedRoot = base.appendingPathComponent("linked-root")
        try fm.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
        XCTAssertThrowsError(try ExportWriteBoundary.validate(linkedRoot.appendingPathComponent("note.md"), root: linkedRoot))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unchanged")
    }

    @MainActor
    func testManifestParentTraversalStopsExportBeforeWritesAndPruning() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("export")
        let folder = root.appendingPathComponent("Test/Folder")
        let outside = base.appendingPathComponent("outside")
        let child = outside.appendingPathComponent("child")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("redirect")
        try fm.createSymbolicLink(at: link, withDestinationURL: child)
        let relative = "Test/Folder/redirect/../First.md"
        let target = root.appendingPathComponent(relative)
        let sentinel = outside.appendingPathComponent("First.md")
        let inside = folder.appendingPathComponent("First.md")
        let original = Data("untouched".utf8)
        try original.write(to: inside)
        let repository = MockNotesRepository()
        repository.mockAccounts = [NotesAccount(id: "account-1", name: "Test", identifier: "test", accountType: .local)]
        repository.mockFolders = [NotesFolder(id: "folder-1", name: "Folder", parentId: nil, accountId: "account-1")]
        let model = ExportViewModel(repository: repository, databasePath: ":memory:")
        model.configurations = .default
        model.configurations.incrementalSync = true
        model.configurations.addDateToFilename = false
        let note = makeNote(id: "first", title: "First")
        for existing in [false, true] {
            if existing { try original.write(to: sentinel) }
            XCTAssertThrowsError(try ExportWriteBoundary.validate(target, root: root))
            let unsafeRoot = link.appendingPathComponent("..")
            XCTAssertThrowsError(try ExportWriteBoundary.validate(target, root: unsafeRoot))
            for staleAttachment in [false, true] {
                var manifest = SyncManifest.empty()
                manifest.recordExport(noteId: staleAttachment ? "deleted" : note.id,
                                      modificationDate: .distantPast,
                                      exportedPath: staleAttachment ? "Test/Folder/old.md" : relative,
                                      attachmentPaths: staleAttachment ? [relative] : [])
                try manifest.save(to: root)
                let watermark = root.appendingPathComponent(SyncManifest.filename)
                let before = try Data(contentsOf: watermark)
                await model.exportNotes([note], toDirectory: root, format: .markdown)
                guard case .error = model.exportState else { return XCTFail("Unsafe manifest must abort sync") }
                XCTAssertEqual(try Data(contentsOf: watermark), before)
                _ = try model.removeManifestEntriesNotInCurrentExportSet(from: &manifest, currentNoteIDs: [], outputRootURL: root)
                XCTAssertEqual(try Data(contentsOf: inside), original)
                if existing { XCTAssertEqual(try Data(contentsOf: sentinel), original) }
                else { XCTAssertFalse(fm.fileExists(atPath: sentinel.path)) }
            }
        }
    }

    func testManifestWriteRejectsSymlinkWithoutChangingOutsideFile() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("export")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let sentinel = base.appendingPathComponent("sentinel")
        try Data("outside".utf8).write(to: sentinel)
        try fm.createSymbolicLink(at: root.appendingPathComponent(SyncManifest.filename), withDestinationURL: sentinel)
        XCTAssertThrowsError(try SyncManifest.empty().save(to: root))
        XCTAssertNil(SyncManifest.load(from: root))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "outside")
    }

    @MainActor
    func testNoteAndConcatenatedTargetsCannotChangeOutsideFile() async throws {
        for concatenate in [false, true] {
            let fm = FileManager.default
            let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let root = base.appendingPathComponent("export")
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: base) }
            let repository = MockNotesRepository()
            repository.mockAccounts = [NotesAccount(id: "account-1", name: "Test", identifier: "test", accountType: .local)]
            repository.mockFolders = [NotesFolder(id: "folder-1", name: "Folder", parentId: nil, accountId: "account-1")]
            let model = ExportViewModel(repository: repository, databasePath: ":memory:")
            model.configurations = .default
            model.configurations.addDateToFilename = false
            model.configurations.incrementalSync = !concatenate
            model.configurations.concatenateOutput = concatenate
            let note = makeNote(id: "first", title: "First")
            await model.exportNotes([note], toDirectory: root, format: .markdown)
            let relativePath = concatenate ? "Exported Notes.md" :
                try XCTUnwrap(SyncManifest.load(from: root)?.notes[note.id]?.exportedPath)
            let target = root.appendingPathComponent(relativePath)
            try fm.removeItem(at: target)
            let sentinel = base.appendingPathComponent("sentinel")
            try Data("outside".utf8).write(to: sentinel)
            let before = try fm.attributesOfItem(atPath: sentinel.path)[.modificationDate] as? Date
            try fm.createSymbolicLink(at: target, withDestinationURL: sentinel)
            // Different source fingerprint forces a write attempt for the existing manifest path.
            let changed = makeNote(id: "first", title: "First", plaintext: "changed body")
            await model.exportNotes([changed], toDirectory: root, format: .markdown)
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "outside")
            XCTAssertEqual(try fm.attributesOfItem(atPath: sentinel.path)[.modificationDate] as? Date, before)
            if case .completed(let stats) = model.exportState {
                XCTAssertGreaterThan(stats.failedNotes, 0)
            } else if case .error = model.exportState {
            } else {
                XCTFail("Redirected note output must fail")
            }
        }
    }

    @MainActor
    func testFullExportCannotWriteThroughFolderOrAttachmentLinks() async throws {
        for linkedPath in ["Test/Folder", "Test/Folder/First (Attachments)", "Test/Folder/First (Attachments)/test.bin"] {
            let fm = FileManager.default
            let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let root = base.appendingPathComponent("export")
            let outside = base.appendingPathComponent("outside")
            let link = root.appendingPathComponent(linkedPath)
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: base) }
            let sentinel = outside.appendingPathComponent("sentinel")
            try Data("outside".utf8).write(to: sentinel)
            let before = try fm.attributesOfItem(atPath: sentinel.path)[.modificationDate] as? Date
            try fm.createSymbolicLink(at: link, withDestinationURL: linkedPath.hasSuffix(".bin") ? sentinel : outside)
            let repository = MockNotesRepository()
            repository.mockAccounts = [NotesAccount(id: "account-1", name: "Test", identifier: "test", accountType: .local)]
            repository.mockFolders = [NotesFolder(id: "folder-1", name: "Folder", parentId: nil, accountId: "account-1")]
            repository.mockAttachmentData = Data("attachment".utf8)
            let model = ExportViewModel(repository: repository, databasePath: ":memory:")
            model.configurations = .default
            model.configurations.incrementalSync = true
            model.configurations.addDateToFilename = false
            let note = makeNote(id: "first", title: "First", attachments: [
                NotesAttachment(id: "file", typeUTI: "public.data", filename: "test.bin")
            ])
            await model.exportNotes([note], toDirectory: root, format: .markdown)
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside.path), ["sentinel"])
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "outside")
            XCTAssertEqual(try fm.attributesOfItem(atPath: sentinel.path)[.modificationDate] as? Date, before)
            if case .completed(let stats) = model.exportState {
                XCTAssertGreaterThan(stats.failedNotes + stats.failedAttachments, 0)
            } else if case .error = model.exportState {
                // Directory guards abort the export before writing notes.
            } else {
                XCTFail("Unsafe output must report failure")
            }
        }
    }
    func testInventoryBrokenFolderSchemaThrowsInsteadOfEmptySuccess() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let database = base.appendingPathComponent("NoteStore.sqlite")
        try createModernNotesDatabase(at: database, additionalSQL: "ALTER TABLE ZICCLOUDSYNCINGOBJECT DROP COLUMN ZPARENT;")
        do {
            let folders = try await DatabaseNotesRepository(databasePath: database.path).fetchFolders()
            XCTFail("Broken folder query returned success with \(folders.count) folders")
        } catch {
            // Expected: incompatible schema must fail closed before mirror planning.
        }
    }

    func testInventoryPartialNoteQueryMustThrow() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let database = base.appendingPathComponent("NoteStore.sqlite")
        try createModernNotesDatabase(at: database, additionalSQL: """
            WITH RECURSIVE numbers(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM numbers WHERE x < 1000)
            INSERT INTO ZICCLOUDSYNCINGOBJECT
                (Z_PK, Z_ENT, ZIDENTIFIER, ZTITLE2, ZCREATIONDATE1, ZMODIFICATIONDATE1, ZFOLDER, ZACCOUNT2, ZMARKEDFORDELETION)
            SELECT x, 1, 'note-' || x, 'Synthetic ' || x, 10, 20, 50, 100, 0 FROM numbers;
            """)
        let db = try XCTUnwrap(ane_open(database.path))
        defer { ane_close(db) }
        let sqlite = OpaquePointer(try XCTUnwrap(ane_get_sqlite_handle(db)))
        let remaining = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        remaining.initialize(to: 5000)
        defer { remaining.deinitialize(count: 1); remaining.deallocate() }
        sqlite3_progress_handler(sqlite, 1, { context in
            guard let remaining = context?.assumingMemoryBound(to: Int32.self) else { return 1 }
            remaining.pointee -= 1
            return remaining.pointee <= 0 ? 1 : 0
        }, remaining)
        var count = 0
        let notes = ane_fetch_notes(db, &count)
        let error = sqlite3_errcode(sqlite)
        sqlite3_progress_handler(sqlite, 0, nil, nil)
        defer { if let notes { ane_free_notes(notes, count) } }
        XCTAssertEqual(error, SQLITE_INTERRUPT)
        XCTAssertNil(notes)
        XCTAssertEqual(count, 0)
        var retryCount = 0
        let retry = try XCTUnwrap(ane_fetch_notes(db, &retryCount))
        defer { ane_free_notes(retry, retryCount) }
        XCTAssertEqual(retryCount, 1000)
    }

    func testEmptyInventoryIsSuccessful() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let database = base.appendingPathComponent("NoteStore.sqlite")
        try createModernNotesDatabase(at: database, additionalSQL: "")
        let repository = DatabaseNotesRepository(databasePath: database.path)
        let accounts = try await repository.fetchAccounts()
        let folders = try await repository.fetchFolders()
        let notes = try await repository.fetchNotes()
        XCTAssertTrue(accounts.isEmpty)
        XCTAssertTrue(folders.isEmpty)
        XCTAssertTrue(notes.isEmpty)
    }

    @MainActor
    func testBrokenInventoryQueriesThrow() async throws {
        for column in ["ZNAME", "ZPARENT", "ZTITLE2"] {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let database = base.appendingPathComponent("NoteStore.sqlite")
            let mutation = column == "ZTITLE2"
                ? "ALTER TABLE ZICNOTEDATA DROP COLUMN ZDATA;"
                : "ALTER TABLE ZICCLOUDSYNCINGOBJECT DROP COLUMN \(column);"
            try createModernNotesDatabase(at: database, additionalSQL: mutation)
            let repository = DatabaseNotesRepository(databasePath: database.path)
            do {
                switch column {
                case "ZNAME": _ = try await repository.fetchAccounts()
                case "ZPARENT": _ = try await repository.fetchFolders()
                default: _ = try await repository.fetchNotes()
                }
                XCTFail("Invalid inventory schema must throw: \(column)")
            } catch RepositoryError.inventoryReadFailed { }
            let model = NotesViewModel(repository: repository)
            await model.loadNotes()
            XCTAssertNotNil(model.loadingState.errorMessage)
            XCTAssertTrue(model.selectedNotes.isEmpty)
        }
    }

    func testInterruptedAccountFolderAndRangeQueriesDiscardRowsAndRetry() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let database = base.appendingPathComponent("NoteStore.sqlite")
        try createModernNotesDatabase(at: database, additionalSQL: """
            WITH RECURSIVE numbers(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM numbers WHERE x < 1000)
            INSERT INTO ZICCLOUDSYNCINGOBJECT
                (Z_PK, Z_ENT, ZIDENTIFIER, ZNAME, ZTITLE2, ZCREATIONDATE1, ZMODIFICATIONDATE1, ZFOLDER, ZACCOUNT2, ZMARKEDFORDELETION)
            SELECT x, 1, 'note-' || x, 'Account', 'Synthetic', 10, 20, 50, 100, 0 FROM numbers;
            UPDATE ZICCLOUDSYNCINGOBJECT SET ZNAME = 'Account', ZTITLE = 'Synthetic',
                ZTITLE1 = 'Synthetic', ZTITLE2 = 'Synthetic';
            """)
        let db = try XCTUnwrap(ane_open(database.path))
        defer { ane_close(db) }
        let sqlite = OpaquePointer(try XCTUnwrap(ane_get_sqlite_handle(db)))
        // Populate each entity before its read; interrupted statements must also be reusable.
        for entity in [3, 4, 1] {
            var writer: OpaquePointer?
            XCTAssertEqual(sqlite3_open(database.path, &writer), SQLITE_OK)
            let writable = try XCTUnwrap(writer)
            try executeSQL("UPDATE ZICCLOUDSYNCINGOBJECT SET Z_ENT = \(entity);", in: writable)
            sqlite3_close(writable)
            var budget: Int32 = 5000
            withUnsafeMutablePointer(to: &budget) { remaining in
                sqlite3_progress_handler(sqlite, 1, { context in
                    let value = context!.assumingMemoryBound(to: Int32.self)
                    value.pointee -= 1
                    return value.pointee <= 0 ? 1 : 0
                }, remaining)
                defer { sqlite3_progress_handler(sqlite, 0, nil, nil) }
                var count = 99
                switch entity {
                case 3:
                    let rows = ane_fetch_accounts(db, &count)
                    defer { if let rows { ane_free_accounts(rows, count) } }
                    XCTAssertNil(rows)
                case 4:
                    let rows = ane_fetch_folders(db, &count)
                    defer { if let rows { ane_free_folders(rows, count) } }
                    XCTAssertNil(rows)
                default:
                    let rows = ane_fetch_notes_in_range(db, 0, 0, &count)
                    defer { if let rows { ane_free_notes(rows, count) } }
                    XCTAssertNil(rows)
                }
                XCTAssertEqual(sqlite3_errcode(sqlite), SQLITE_INTERRUPT)
                XCTAssertEqual(count, 0)
            }
            var count = 0
            switch entity {
            case 3:
                let rows = try XCTUnwrap(ane_fetch_accounts(db, &count))
                ane_free_accounts(rows, count)
            case 4:
                let rows = try XCTUnwrap(ane_fetch_folders(db, &count))
                ane_free_folders(rows, count)
            default:
                let rows = try XCTUnwrap(ane_fetch_notes_in_range(db, 0, 0, &count))
                ane_free_notes(rows, count)
            }
            XCTAssertEqual(count, 1000)
        }
    }

    @MainActor
    func testNewDuplicateCannotClaimExistingNotesExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = makeNote(id: "original", title: "Shared Title")
        let added = makeNote(id: "added", title: "Shared Title")
        let originalURL = root.appendingPathComponent("Shared Title.md")
        try "original body".write(to: originalURL, atomically: true, encoding: .utf8)
        var manifest = SyncManifest.empty()
        manifest.recordExport(noteId: original.id, modificationDate: original.modificationDate,
                              exportedPath: "Shared Title.md", contentFingerprint: NoteContentFingerprint.value(for: original))
        let model = ExportViewModel(repository: MockNotesRepository())
        model.configurations.addDateToFilename = false
        for notes in [[added, original], [original, added]] {
            let plan = model.buildExportPlan(for: notes.map { (note: $0, folderURL: root) },
                                            format: .markdown, rootURL: root, syncManifest: manifest, isSync: true)
            XCTAssertEqual(plan[original.id]?.fileURL, originalURL)
            XCTAssertNotEqual(plan[original.id]?.fileURL, plan[added.id]?.fileURL)
            XCTAssertNotEqual(plan[original.id]?.uniqueBaseName, plan[added.id]?.uniqueBaseName)
        }
        XCTAssertEqual(try String(contentsOf: originalURL, encoding: .utf8), "original body")
    }

    @MainActor
    func testDuplicatePlansKeepBodiesAttachmentsLinksAndIncrementalPathsSeparate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = [makeNote(id: "first", title: "Duplicate", plaintext: "First body"),
                     makeNote(id: "second", title: "Duplicate", plaintext: "Second body")]
        let repository = MockNotesRepository()
        let model = ExportViewModel(repository: repository, databasePath: ":memory:")
        model.configurations.addDateToFilename = false
        let plan = model.buildExportPlan(for: notes.map { (note: $0, folderURL: root) },
                                        format: .markdown, rootURL: root, syncManifest: nil, isSync: true)
        var manifest = SyncManifest.empty()
        for note in notes {
            let entry = try XCTUnwrap(plan[note.id])
            try note.plaintext.write(to: entry.fileURL, atomically: true, encoding: .utf8)
            repository.mockAttachmentData = Data(note.id.utf8)
            let paths = try await model.exportAttachmentsAndReturnPaths(
                [NotesAttachment(id: note.id, typeUTI: "public.data", filename: "file.bin")],
                toDirectory: root, noteBaseName: entry.uniqueBaseName, noteTitle: note.title,
                noteCreationDate: note.creationDate, noteModificationDate: note.modificationDate,
                tracker: ExportProgressTracker())
            let attachmentPath = try XCTUnwrap(paths[note.id])
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(attachmentPath)), Data(note.id.utf8))
            manifest.recordExport(noteId: note.id, modificationDate: note.modificationDate,
                                  exportedPath: entry.fileURL.lastPathComponent, attachmentPaths: [attachmentPath],
                                  contentFingerprint: NoteContentFingerprint.value(for: note))
        }
        let repeatPlan = model.buildExportPlan(for: notes.reversed().map { (note: $0, folderURL: root) },
                                              format: .markdown, rootURL: root, syncManifest: manifest, isSync: true)
        for note in notes {
            XCTAssertEqual(repeatPlan[note.id]?.fileURL, plan[note.id]?.fileURL)
            XCTAssertEqual(try String(contentsOf: XCTUnwrap(plan[note.id]?.fileURL), encoding: .utf8), note.plaintext)
        }
        XCTAssertTrue(manifest.notesNeedingExport(from: notes, contentFingerprint: { NoteContentFingerprint.value(for: $0) }).isEmpty)
        let links = model.noteLinkTargets(for: notes[0], rootURL: root, exportPlan: repeatPlan)
        XCTAssertEqual(links[notes[1].id]?.obsidianReference, plan[notes[1].id]?.uniqueBaseName)
        XCTAssertEqual(try model.removeManifestEntriesNotInCurrentExportSet(
            from: &manifest, currentNoteIDs: [notes[1].id], outputRootURL: root), 1)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(plan[notes[1].id]?.fileURL), encoding: .utf8), notes[1].plaintext)
        let survivorAttachment = try XCTUnwrap(manifest.notes[notes[1].id]?.attachmentPaths.first)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(survivorAttachment)), Data(notes[1].id.utf8))
    }

    @MainActor
    func testMovedOrRenamedNoteCannotTakeAnotherNotesPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resident = makeNote(id: "resident", title: "Destination")
        let changed = makeNote(id: "changed", title: "Destination")
        let model = ExportViewModel(repository: MockNotesRepository(), databasePath: ":memory:")
        model.configurations.addDateToFilename = false
        // Also reserve the resident's path when its file needs to be recreated.
        for existingFile in [false, true] {
            if existingFile {
                try "resident".write(to: root.appendingPathComponent("Destination.md"), atomically: true, encoding: .utf8)
            }
            for priorPath in ["Old Title.md", "Old Folder/Destination.md"] {
                var manifest = SyncManifest.empty()
                for (note, path) in [(resident, "Destination.md"), (changed, priorPath)] {
                    manifest.recordExport(noteId: note.id, modificationDate: note.modificationDate, exportedPath: path)
                }
                let plan = model.buildExportPlan(for: [changed, resident].map { (note: $0, folderURL: root) },
                                                format: .markdown, rootURL: root, syncManifest: manifest, isSync: true)
                XCTAssertEqual(plan[resident.id]?.fileURL.lastPathComponent, "Destination.md")
                XCTAssertEqual(plan[changed.id]?.fileURL.lastPathComponent, "Destination (2).md")
            }
        }
    }

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    @MainActor
    func testCaseAndUnicodeAliasesReceiveSeparateExportPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = ExportViewModel(repository: MockNotesRepository(), databasePath: ":memory:")
        model.configurations = .default
        for titles in [["Same", "same"], ["Caf\u{e9}", "Cafe\u{301}"]] {
            let notes = titles.enumerated().map { makeNote(id: "note-\($0.offset)", title: $0.element) }
            let plan = model.buildExportPlan(for: notes.map { (note: $0, folderURL: root) },
                                            format: .markdown, rootURL: root, syncManifest: nil, isSync: true)
            XCTAssertEqual(Set(plan.values.map { ExportPathIdentity.key($0.fileURL.path) }).count, 2)
            var manifest = SyncManifest.empty()
            for note in notes {
                manifest.recordExport(noteId: note.id, modificationDate: note.modificationDate,
                                      exportedPath: note.title + ".md", contentFingerprint: NoteContentFingerprint.value(for: note))
            }
            XCTAssertEqual(manifest.collidingNoteIDs, Set(notes.map(\.id)))
            XCTAssertEqual(manifest.notesNeedingExport(from: notes, contentFingerprint: { NoteContentFingerprint.value(for: $0) }).count, 2)
        }
    }

    @MainActor
    func testLegacyCollisionRepairThroughFullExportAndNoOpIncludingFailure() async throws {
        for failRepair in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let repository = CollisionTestRepository()
            repository.mockAccounts = [NotesAccount(id: "account-1", name: "Test", identifier: "test", accountType: .local)]
            repository.mockFolders = [NotesFolder(id: "folder-1", name: "Folder", parentId: nil, accountId: "account-1")]
            repository.mockAttachmentData = Data("attachment".utf8)
            let notes = ["first", "second", "source"].map {
                makeNote(id: $0, title: $0.capitalized, attachments: [NotesAttachment(id: $0, typeUTI: "public.data", filename: "test.bin")])
            }
            let model = ExportViewModel(repository: repository, databasePath: ":memory:")
            model.configurations = .default
            model.configurations.incrementalSync = true
            model.configurations.obsidianInternalLinksInMarkdown = true
            await model.exportNotes(notes, toDirectory: root, format: .markdown)
            var manifest = try XCTUnwrap(SyncManifest.load(from: root))
            let shared = try XCTUnwrap(manifest.notes["first"])
            manifest.notes["second"]?.exportedPath = shared.exportedPath
            manifest.notes["second"]?.attachmentPaths = shared.attachmentPaths
            try manifest.save(to: root)
            repository.failingID = failRepair ? "second" : nil
            repository.blockedOutput = root.appendingPathComponent(shared.exportedPath)
                .deletingLastPathComponent().appendingPathComponent("Second (2).md")
            await model.exportNotes(notes, toDirectory: root, format: .markdown)
            if failRepair {
                guard case .completed(let failedStats) = model.exportState else { return XCTFail("Expected failed-note summary") }
                XCTAssertEqual(failedStats.failedNotes, 1)
                XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(shared.exportedPath).path))
                for path in shared.attachmentPaths {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
                }
                repository.failingID = nil
                try FileManager.default.removeItem(at: XCTUnwrap(repository.blockedOutput))
                await model.exportNotes(notes, toDirectory: root, format: .markdown)
            }
            manifest = try XCTUnwrap(SyncManifest.load(from: root))
            XCTAssertEqual(manifest.notes.count, 3)
            XCTAssertTrue(manifest.collidingNoteIDs.isEmpty)
            XCTAssertNil(manifest.collisionLinkRefreshPending)
            let sourcePath = try XCTUnwrap(manifest.notes["source"]?.exportedPath)
            let sourceBody = try String(contentsOf: root.appendingPathComponent(sourcePath), encoding: .utf8)
            for id in ["first", "second"] {
                let target = try XCTUnwrap(manifest.notes[id]?.exportedPath)
                XCTAssertTrue(sourceBody.contains(String(target.dropLast(3))))
            }
            for note in notes {
                let entry = try XCTUnwrap(manifest.notes[note.id])
                let body = try String(contentsOf: root.appendingPathComponent(entry.exportedPath), encoding: .utf8)
                XCTAssertTrue(body.contains("Mock HTML for note \(note.id)"))
                XCTAssertEqual(entry.attachmentPaths.count, 1)
                for path in entry.attachmentPaths {
                    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), repository.mockAttachmentData)
                }
            }
            let pathsBefore = manifest.notes.mapValues(\.exportedPath)
            await model.exportNotes(notes, toDirectory: root, format: .markdown)
            guard case .completed(let stats) = model.exportState else { return XCTFail("Expected completed export") }
            XCTAssertEqual(stats.successfulNotes, 0)
            XCTAssertEqual(try XCTUnwrap(SyncManifest.load(from: root)).notes.mapValues(\.exportedPath), pathsBefore)
        }
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

    func testModernNotesDatabaseUsesRecognizedHandwritingTitleColumn() throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleNotesTitleColumns-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = fixtureURL.appendingPathComponent("NoteStore.sqlite")
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        try createModernNotesDatabase(
            at: databaseURL,
            additionalSQL: """
            INSERT INTO ZICCLOUDSYNCINGOBJECT
                (Z_PK, Z_ENT, ZIDENTIFIER, ZTITLE, ZTITLE1, ZTITLE2,
                 ZCREATIONDATE1, ZMODIFICATIONDATE1, ZFOLDER, ZACCOUNT2, ZMARKEDFORDELETION)
            VALUES
                (1, 1, 'typed', 'Legacy typed', 'Older typed', 'Typed title', 10, 20, 50, 100, 0),
                (2, 1, 'handwritten', NULL, 'Recognized handwriting', NULL, 11, 21, 50, 100, 0),
                (3, 1, 'legacy-title', 'Legacy title', NULL, NULL, 12, 22, 50, 100, 0),
                (4, 1, 'pure-ink', NULL, NULL, NULL, 13, 23, 50, 100, 0);
            """
        )

        let db = try XCTUnwrap(ane_open(databaseURL.path))
        defer { ane_close(db) }

        var count = 0
        let notes = try XCTUnwrap(ane_fetch_notes(db, &count))
        defer { ane_free_notes(notes, count) }

        let notesByPrimaryKey = (0..<count).map { index in
            let note = notes[index]
            return (note.pk, note.title.map { String(cString: $0) })
        }.sorted { $0.0 < $1.0 }

        XCTAssertEqual(notesByPrimaryKey.count, 4)
        XCTAssertEqual(notesByPrimaryKey[0].1, "Typed title")
        XCTAssertEqual(notesByPrimaryKey[1].1, "Recognized handwriting")
        XCTAssertEqual(notesByPrimaryKey[2].1, "Legacy title")
        XCTAssertNil(notesByPrimaryKey[3].1)
    }

    func testRecognizedTitleCorrectionTriggersOnlyAffectedIncrementalExport() throws {
        let oldHandwritten = makeNote(
            id: "handwritten",
            title: NotesNote.fallbackTitle(for: "handwritten"),
            plaintext: ""
        )
        let correctedHandwritten = makeNote(
            id: "handwritten",
            title: "Recognized handwriting",
            plaintext: ""
        )
        let unchanged = makeNote(
            id: "unchanged",
            title: "Typed title",
            plaintext: "Body"
        )

        var manifest = SyncManifest.empty()
        for note in [oldHandwritten, unchanged] {
            manifest.recordExport(
                noteId: note.id,
                modificationDate: note.modificationDate,
                exportedPath: "iCloud/\(note.sanitizedFileName).md",
                contentFingerprint: NoteContentFingerprint.value(for: note)
            )
        }

        let notesNeedingExport = manifest.notesNeedingExport(
            from: [correctedHandwritten, unchanged],
            contentFingerprint: { NoteContentFingerprint.value(for: $0) }
        )

        XCTAssertEqual(notesNeedingExport.map(\.id), ["handwritten"])
    }

    func testGalleryChildWithoutMediaUsesOnMyMacFallbackImage() throws {
        let fileManager = FileManager.default
        let fixtureURL = fileManager.temporaryDirectory
            .appendingPathComponent("AppleNotesGalleryFallback-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = fixtureURL.appendingPathComponent("NoteStore.sqlite")
        let fallbackURL = fixtureURL
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes/Accounts/LocalAccount/FallbackImages", isDirectory: true)
            .appendingPathComponent("gallery-child.jpg")
        let expectedData = Data([0xFF, 0xD8, 0xFF, 0xD9])

        try fileManager.createDirectory(at: fallbackURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try expectedData.write(to: fallbackURL)
        defer { try? fileManager.removeItem(at: fixtureURL) }

        try createModernNotesDatabase(
            at: databaseURL,
            additionalSQL: """
            INSERT INTO ZICCLOUDSYNCINGOBJECT
                (Z_PK, Z_ENT, ZIDENTIFIER, ZNAME, ZMARKEDFORDELETION)
            VALUES (100, 3, 'LocalAccount', 'On My Mac', 0);

            INSERT INTO ZICCLOUDSYNCINGOBJECT
                (Z_PK, Z_ENT, ZIDENTIFIER, ZTITLE2, ZCREATIONDATE1,
                 ZMODIFICATIONDATE1, ZFOLDER, ZACCOUNT2, ZMARKEDFORDELETION)
            VALUES (200, 1, 'note-with-gallery', 'Gallery note', 10, 20, 50, 100, 0);

            INSERT INTO ZICCLOUDSYNCINGOBJECT
                (Z_PK, Z_ENT, ZIDENTIFIER, ZTYPEUTI, ZNOTE, ZMARKEDFORDELETION)
            VALUES (300, 2, 'gallery-parent', 'com.apple.notes.gallery', 200, 0);

            INSERT INTO ZICCLOUDSYNCINGOBJECT
                (Z_PK, Z_ENT, ZIDENTIFIER, ZTYPEUTI, ZFILENAME, ZMEDIA,
                 ZNOTE, ZPARENTATTACHMENT, ZMARKEDFORDELETION)
            VALUES (301, 2, 'gallery-child', 'public.jpeg', NULL, NULL, 200, 300, 0);
            """
        )

        let originalHome = getenv("HOME").map { String(cString: $0) }
        XCTAssertEqual(setenv("HOME", fixtureURL.path, 1), 0)
        defer {
            if let originalHome {
                setenv("HOME", originalHome, 1)
            } else {
                unsetenv("HOME")
            }
        }

        let db = try XCTUnwrap(ane_open(databaseURL.path))
        defer { ane_close(db) }
        XCTAssertGreaterThanOrEqual(ane_prefetch_attachments(db), 2)

        var count = 0
        let children = try XCTUnwrap(ane_fetch_gallery_children(db, "gallery-parent", nil, &count))
        defer { ane_free_gallery_children(children, count) }

        XCTAssertEqual(count, 1)
        let child = children[0]
        XCTAssertEqual(child.identifier.map { String(cString: $0) }, "gallery-child")
        XCTAssertEqual(child.filename.map { String(cString: $0) }, "gallery-child.jpg")
        XCTAssertEqual(child.type_uti.map { String(cString: $0) }, "public.jpeg")
        XCTAssertEqual(child.data_len, expectedData.count)
        let actualData = child.data.map { Data(bytes: $0, count: child.data_len) }
        XCTAssertEqual(actualData, expectedData)
    }

    @MainActor
    func testGalleryChildrenExportAsSeparateObsidianEmbeds() async throws {
        let fileManager = FileManager.default
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("AppleNotesGalleryExport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: outputURL) }

        let repository = MockNotesRepository()
        repository.mockGalleryChildren = [
            GalleryChild(
                id: "gallery-child-1",
                data: Data([0xFF, 0xD8, 0x01, 0xD9]),
                filename: "First Photo.jpg",
                uti: "public.jpeg"
            ),
            GalleryChild(
                id: "gallery-child-2",
                data: Data([0x89, 0x50, 0x4E, 0x47]),
                filename: "Second Photo.png",
                uti: "public.png"
            )
        ]
        let viewModel = ExportViewModel(repository: repository, databasePath: ":memory:")
        let tracker = ExportProgressTracker()
        let gallery = NotesAttachment(
            id: "gallery-parent",
            typeUTI: "com.apple.notes.gallery",
            filename: nil
        )

        let attachmentPaths = try await viewModel.exportAttachmentsAndReturnPaths(
            [gallery],
            toDirectory: outputURL,
            noteBaseName: "Gallery Note",
            noteTitle: "Gallery Note",
            noteCreationDate: Date(timeIntervalSince1970: 1_700_000_000),
            noteModificationDate: Date(timeIntervalSince1970: 1_700_000_100),
            tracker: tracker
        )

        let firstPath = "Gallery Note (Attachments)/First Photo.jpg"
        let secondPath = "Gallery Note (Attachments)/Second Photo.png"
        XCTAssertEqual(attachmentPaths[gallery.id], firstPath)
        XCTAssertEqual(
            attachmentPaths[GalleryAttachmentPaths.additionalPathKey(parentId: gallery.id, index: 1)],
            secondPath
        )
        XCTAssertTrue(fileManager.fileExists(atPath: outputURL.appendingPathComponent(firstPath).path))
        XCTAssertTrue(fileManager.fileExists(atPath: outputURL.appendingPathComponent(secondPath).path))
        let stats = await tracker.getStats()
        XCTAssertEqual(stats.failedAttachments, 0)

        var sqlite: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &sqlite), SQLITE_OK)
        let database = try XCTUnwrap(sqlite)
        defer { sqlite3_close(database) }

        let processedHTML = HTMLAttachmentProcessor(database: database).processHTML(
            html: #"<html><body><span data-attachment-id="gallery-parent" data-attachment-type="com.apple.notes.gallery">￼</span></body></html>"#,
            attachments: [gallery],
            attachmentPaths: attachmentPaths,
            embedImages: false,
            linkEmbeddedImages: false
        )
        let markdown = makeNote(htmlBody: processedHTML, attachments: [gallery])
            .toMarkdown(flavor: .obsidian)

        XCTAssertTrue(markdown.contains("![[\(firstPath)]]"))
        XCTAssertTrue(markdown.contains("![[\(secondPath)]]"))
    }

    @MainActor
    func testDrawingFallbackUsesExtensionDetectedFromBytes() async throws {
        let fileManager = FileManager.default
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("AppleNotesDrawingExport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: outputURL) }

        let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
        let repository = MockNotesRepository()
        repository.mockAttachmentData = pngData
        repository.mockAttachmentFilename = "drawing-fallback.jpg"
        let viewModel = ExportViewModel(repository: repository, databasePath: ":memory:")
        let tracker = ExportProgressTracker()
        let drawing = NotesAttachment(
            id: "drawing-fallback",
            typeUTI: "com.apple.drawing.2",
            filename: nil
        )

        let attachmentPaths = try await viewModel.exportAttachmentsAndReturnPaths(
            [drawing],
            toDirectory: outputURL,
            noteBaseName: "Handwritten Note",
            noteTitle: "Handwritten Note",
            noteCreationDate: Date(timeIntervalSince1970: 1_700_000_000),
            noteModificationDate: Date(timeIntervalSince1970: 1_700_000_100),
            tracker: tracker
        )

        let expectedPath = "Handwritten Note (Attachments)/drawing-fallback.png"
        XCTAssertEqual(attachmentPaths[drawing.id], expectedPath)
        XCTAssertEqual(try Data(contentsOf: outputURL.appendingPathComponent(expectedPath)), pngData)
        let stats = await tracker.getStats()
        XCTAssertEqual(stats.failedAttachments, 0)
    }

    func testAttachmentFileSignaturePreservesJPEGExtensionAliases() {
        let jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0])

        XCTAssertEqual(AttachmentFileSignature.fileExtension(for: jpegData), "jpg")
        XCTAssertTrue(AttachmentFileSignature.matches("jpeg", "jpg"))
        XCTAssertFalse(AttachmentFileSignature.matches("png", "jpg"))
    }

    func testNormalIncrementalSyncIgnoresRendererVersionUntilRefreshIsExplicit() {
        let staleNote = makeNote(id: "stale-renderer", title: "Stale Renderer")
        let currentNote = makeNote(id: "current-renderer", title: "Current Renderer")
        var manifest = SyncManifest.empty()

        manifest.recordExport(
            noteId: staleNote.id,
            modificationDate: staleNote.modificationDate,
            exportedPath: "iCloud/Stale Renderer.md",
            contentFingerprint: NoteContentFingerprint.value(for: staleNote)
        )
        manifest.recordExport(
            noteId: currentNote.id,
            modificationDate: currentNote.modificationDate,
            exportedPath: "iCloud/Current Renderer.md",
            contentFingerprint: NoteContentFingerprint.value(for: currentNote),
            markdownRendererVersion: MarkdownRenderer.currentVersion
        )

        let normalSelection = manifest.notesNeedingExport(
            from: [staleNote, currentNote],
            contentFingerprint: { NoteContentFingerprint.value(for: $0) }
        )
        let refreshSelection = manifest.notesNeedingExport(
            from: [staleNote, currentNote],
            contentFingerprint: { NoteContentFingerprint.value(for: $0) },
            markdownRendererRefreshVersion: MarkdownRenderer.currentVersion
        )

        XCTAssertTrue(normalSelection.isEmpty)
        XCTAssertEqual(refreshSelection.map(\.id), [staleNote.id])
    }

    func testSuccessfulRendererRefreshSettlesToNormalAndRefreshNoOp() {
        let note = makeNote(id: "refreshed-note", title: "Refreshed Note")
        var manifest = SyncManifest.empty()
        manifest.recordExport(
            noteId: note.id,
            modificationDate: note.modificationDate,
            exportedPath: "iCloud/Refreshed Note.md",
            contentFingerprint: NoteContentFingerprint.value(for: note),
            markdownRendererVersion: MarkdownRenderer.currentVersion
        )

        let normalSelection = manifest.notesNeedingExport(
            from: [note],
            contentFingerprint: { NoteContentFingerprint.value(for: $0) }
        )
        let refreshSelection = manifest.notesNeedingExport(
            from: [note],
            contentFingerprint: { NoteContentFingerprint.value(for: $0) },
            markdownRendererRefreshVersion: MarkdownRenderer.currentVersion
        )

        XCTAssertTrue(normalSelection.isEmpty)
        XCTAssertTrue(refreshSelection.isEmpty)
        XCTAssertEqual(
            manifest.notes[note.id]?.markdownRendererVersion,
            MarkdownRenderer.currentVersion
        )
    }

    func testUnrecordedRendererRefreshRemainsEligibleAfterPartialSuccess() {
        let successfulNote = makeNote(id: "successful-refresh", title: "Successful Refresh")
        let failedOrCancelledNote = makeNote(id: "unfinished-refresh", title: "Unfinished Refresh")
        var manifest = SyncManifest.empty()

        for note in [successfulNote, failedOrCancelledNote] {
            manifest.recordExport(
                noteId: note.id,
                modificationDate: note.modificationDate,
                exportedPath: "iCloud/\(note.title).md",
                contentFingerprint: NoteContentFingerprint.value(for: note)
            )
        }

        manifest.recordExport(
            noteId: successfulNote.id,
            modificationDate: successfulNote.modificationDate,
            exportedPath: "iCloud/Successful Refresh.md",
            contentFingerprint: NoteContentFingerprint.value(for: successfulNote),
            markdownRendererVersion: MarkdownRenderer.currentVersion
        )

        let remainingPlan = manifest.markdownRendererRefreshPlan(
            from: [successfulNote, failedOrCancelledNote],
            currentVersion: MarkdownRenderer.currentVersion
        )

        XCTAssertEqual(remainingPlan.map(\.noteId), [failedOrCancelledNote.id])
        XCTAssertNil(manifest.notes[failedOrCancelledNote.id]?.markdownRendererVersion)
    }

    func testLegacyManifestWithoutRendererVersionRemainsReadableAndRefreshEligible() throws {
        let json = """
        {
          "lastSync": 1700000100,
          "notes": {
            "legacy-note": {
              "attachmentPaths": [],
              "contentFingerprint": "fingerprint",
              "exportedPath": "iCloud/Legacy Note.md",
              "modificationDate": 1700000100
            }
          },
          "version": 1
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let manifest = try decoder.decode(SyncManifest.self, from: Data(json.utf8))
        let note = makeNote(
            id: "legacy-note",
            title: "Legacy Note",
            modificationDate: Date(timeIntervalSince1970: 1_700_000_100)
        )

        XCTAssertNil(manifest.notes[note.id]?.markdownRendererVersion)
        XCTAssertEqual(
            manifest.markdownRendererRefreshPlan(
                from: [note],
                currentVersion: MarkdownRenderer.currentVersion
            ).map(\.exportedPath),
            ["iCloud/Legacy Note.md"]
        )
    }

    @MainActor
    func testRendererDryRunPlanDoesNotWriteDeleteOrUpdateManifest() async throws {
        let fileManager = FileManager.default
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("AppleNotesRendererDryRun-\(UUID().uuidString)", isDirectory: true)
        let noteURL = outputURL.appendingPathComponent("iCloud/Legacy Note.md")
        let orphanURL = outputURL.appendingPathComponent("iCloud/Orphan.md")
        try fileManager.createDirectory(at: noteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "legacy markdown".write(to: noteURL, atomically: true, encoding: .utf8)
        try "preserve me".write(to: orphanURL, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: outputURL) }

        let note = makeNote(id: "legacy-note", title: "Legacy Note")
        var manifest = SyncManifest.empty()
        manifest.recordExport(
            noteId: note.id,
            modificationDate: note.modificationDate,
            exportedPath: "iCloud/Legacy Note.md",
            contentFingerprint: NoteContentFingerprint.value(for: note)
        )
        try manifest.save(to: outputURL)
        let manifestURL = outputURL.appendingPathComponent(SyncManifest.filename)
        let manifestBefore = try Data(contentsOf: manifestURL)

        let plan = try await ExportViewModel(repository: MockNotesRepository()).markdownRendererRefreshPlan(
            for: [note],
            outputURL: outputURL,
            format: .markdown
        )

        XCTAssertEqual(plan.map(\.exportedPath), ["iCloud/Legacy Note.md"])
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "legacy markdown")
        XCTAssertEqual(try String(contentsOf: orphanURL, encoding: .utf8), "preserve me")
    }

    func testLaunchOptionsParseExplicitRendererRefreshDryRun() throws {
        let options = try XCTUnwrap(LaunchExportOptions.parse(arguments: [
            "Apple Notes Exporter",
            "--output", "/tmp/apple-notes-renderer-preview",
            "--format", "markdown",
            "--refresh-renderer",
            "--dry-run"
        ]))

        XCTAssertTrue(options.incrementalSync)
        XCTAssertTrue(options.refreshRenderer)
        XCTAssertTrue(options.dryRun)
        XCTAssertNil(options.obsidianInternalLinksInMarkdown)
    }

    func testLaunchOptionsParseExplicitObsidianLinkSetting() throws {
        let enabled = try XCTUnwrap(LaunchExportOptions.parse(arguments: [
            "Apple Notes Exporter",
            "--output", "/tmp/apple-notes-obsidian-links",
            "--format", "markdown",
            "--incremental",
            "--obsidian-links"
        ]))
        let disabled = try XCTUnwrap(LaunchExportOptions.parse(arguments: [
            "Apple Notes Exporter",
            "--output", "/tmp/apple-notes-plain-links",
            "--format", "markdown",
            "--incremental",
            "--no-obsidian-links"
        ]))

        XCTAssertEqual(enabled.obsidianInternalLinksInMarkdown, true)
        XCTAssertEqual(disabled.obsidianInternalLinksInMarkdown, false)
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
    func testStaleManifestCleanupDoesNotFollowSymlinkOutsideOutputRoot() throws {
        let fileManager = FileManager.default
        let baseURL = fileManager.temporaryDirectory
            .appendingPathComponent("AppleNotesExporterSymlinkGuard-\(UUID().uuidString)", isDirectory: true)
        let outputRootURL = baseURL.appendingPathComponent("Export", isDirectory: true)
        let insideFolderURL = outputRootURL.appendingPathComponent("iCloud", isDirectory: true)
        let outsideFolderURL = baseURL.appendingPathComponent("Outside", isDirectory: true)
        let outsideFileURL = outsideFolderURL.appendingPathComponent("outside.md")
        let symlinkURL = insideFolderURL.appendingPathComponent("Linked")

        try fileManager.createDirectory(at: insideFolderURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outsideFolderURL, withIntermediateDirectories: true)
        try "outside".write(to: outsideFileURL, atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideFolderURL)
        defer { try? fileManager.removeItem(at: baseURL) }

        var manifest = SyncManifest.empty()
        manifest.recordExport(
            noteId: "stale-symlink-note",
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            exportedPath: "iCloud/Linked/outside.md"
        )

        let removedCount = try ExportViewModel().removeManifestEntriesNotInCurrentExportSet(
            from: &manifest,
            currentNoteIDs: [],
            outputRootURL: outputRootURL
        )

        XCTAssertEqual(removedCount, 1)
        XCTAssertTrue(fileManager.fileExists(atPath: outsideFileURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: symlinkURL.path))
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

    func testProcessedPDFAttachmentBecomesMarkdownLink() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let attachment = NotesAttachment(
            id: "pdf-1",
            typeUTI: "public.pdf",
            filename: "Vision Plan.pdf"
        )
        let attachmentPath = "Research Note (Attachments)/Vision Plan.pdf"
        let rawHTML = #"""
        <html><body>
        <p>Review this:</p>
        <span data-attachment-id="pdf-1" data-attachment-type="public.pdf">￼</span>
        </body></html>
        """#

        let processedHTML = HTMLAttachmentProcessor(database: db!).processHTML(
            html: rawHTML,
            attachments: [attachment],
            attachmentPaths: ["pdf-1": attachmentPath],
            embedImages: false,
            linkEmbeddedImages: false
        )
        let note = makeNote(htmlBody: processedHTML, attachments: [attachment])
        let markdown = note.toMarkdown(flavor: .obsidian)

        XCTAssertTrue(markdown.contains("[Vision Plan.pdf](\(attachmentPath))"))
        XCTAssertFalse(markdown.contains("data-attachment-id"))
        XCTAssertFalse(markdown.contains("[PDF:"))
    }

    func testProcessedGenericFileAttachmentBecomesMarkdownLink() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let attachment = NotesAttachment(
            id: "file-1",
            typeUTI: "public.zip-archive",
            filename: "Course Materials.zip"
        )
        let attachmentPath = "Research Note (Attachments)/Course Materials.zip"
        let rawHTML = #"""
        <html><body>
        <p>Archive:</p>
        <span data-attachment-id="file-1" data-attachment-type="public.zip-archive">￼</span>
        </body></html>
        """#

        let processedHTML = HTMLAttachmentProcessor(database: db!).processHTML(
            html: rawHTML,
            attachments: [attachment],
            attachmentPaths: ["file-1": attachmentPath],
            embedImages: false,
            linkEmbeddedImages: false
        )
        let note = makeNote(htmlBody: processedHTML, attachments: [attachment])
        let markdown = note.toMarkdown(flavor: .obsidian)

        XCTAssertTrue(markdown.contains("[Course Materials.zip](\(attachmentPath))"))
        XCTAssertFalse(markdown.contains("data-attachment-id"))
        XCTAssertFalse(markdown.contains("[Attachment:"))
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

    func testNoteHTMLGeneratorEscapesLiteralHTMLText() throws {
        let text = #"<b>literal</b> & "quotes" 'single'"#
        let html = generatedHTML(text: text, runs: [attributeRun(for: text)])

        XCTAssertTrue(html.contains("&lt;b&gt;literal&lt;/b&gt; &amp; &quot;quotes&quot; &#39;single&#39;"))
        XCTAssertFalse(html.contains("<b>literal</b>"))
    }

    func testNoteHTMLGeneratorEscapesLiteralHTMLInsideListItems() throws {
        let text = #"<script>alert("not markup")</script>"#
        var style = ParagraphStyle()
        style.styleType = 102
        style.indentAmount = 0
        let html = generatedHTML(
            text: text,
            runs: [attributeRun(for: text, paragraphStyle: style)]
        )

        XCTAssertTrue(html.contains("&lt;script&gt;alert(&quot;not markup&quot;)&lt;/script&gt;"))
        XCTAssertFalse(html.contains("<script>"))
    }

    func testEscapedListTextSurvivesObsidianMarkdownConversion() throws {
        let text = #"<script>alert("not markup")</script>"#
        var style = ParagraphStyle()
        style.styleType = 102
        style.indentAmount = 0
        let html = generatedHTML(
            text: text,
            runs: [attributeRun(for: text, paragraphStyle: style)]
        )
        let markdown = makeNote(htmlBody: html).toMarkdown(flavor: .obsidian)

        XCTAssertTrue(markdown.contains(#"1. &lt;script&gt;alert("not markup")&lt;/script&gt;"#))
        XCTAssertFalse(markdown.contains("<script>"))
    }

    func testNoteHTMLGeneratorEscapesAllowedLinkHref() throws {
        let text = "Search"
        let href = " HTTPS://example.com/search?q=a&label='quoted' "
        let html = generatedHTML(
            text: text,
            runs: [attributeRun(for: text, link: href)]
        )

        XCTAssertTrue(html.contains("href='HTTPS://example.com/search?q=a&amp;label=&#39;quoted&#39;'"))
        XCTAssertFalse(html.contains("href=' HTTPS://"))
    }

    func testNoteHTMLGeneratorAllowsSupportedLinkSchemes() throws {
        let supportedLinks = [
            "http://example.com",
            "https://example.com",
            "mailto:person@example.com",
            "applenotes://note/NOTE-ID",
            "tel:+15555550123",
            "sms:+15555550123",
            "ftp://example.com/file.txt"
        ]

        for href in supportedLinks {
            let text = "Supported link"
            let html = generatedHTML(
                text: text,
                runs: [attributeRun(for: text, link: href)]
            )

            XCTAssertTrue(html.contains("href='\(href)'"), "Expected allowed href for \(href)")
        }
    }

    func testNoteHTMLGeneratorBlocksUnsafeLinkSchemes() throws {
        let unsafeLinks = [
            "javascript:alert(1)",
            " data:text/html,<script>alert(1)</script> ",
            "vbscript:msgbox(1)",
            "file:///tmp/private"
        ]

        for href in unsafeLinks {
            let text = "Unsafe link"
            let html = generatedHTML(
                text: text,
                runs: [attributeRun(for: text, link: href)]
            )

            XCTAssertTrue(html.contains("href='#'"), "Expected blocked href for \(href)")
            XCTAssertFalse(html.lowercased().contains("href='javascript:"))
            XCTAssertFalse(html.lowercased().contains("href='data:"))
            XCTAssertFalse(html.lowercased().contains("href='vbscript:"))
            XCTAssertFalse(html.lowercased().contains("href='file:"))
        }
    }

    func testBlockedLinkProducesInertObsidianMarkdownDestination() throws {
        let text = "Unsafe link"
        let html = generatedHTML(
            text: text,
            runs: [attributeRun(for: text, link: "javascript:alert(1)")]
        )
        let markdown = makeNote(htmlBody: html).toMarkdown(flavor: .obsidian)

        XCTAssertTrue(markdown.contains("[Unsafe link](#)"))
        XCTAssertFalse(markdown.lowercased().contains("javascript:"))
    }

    func testSanitizedAppleNotesLinkStillBecomesObsidianWikilink() throws {
        let text = "Plateau note"
        let href = "applenotes://show?identifier=x-coredata://ABCDEF-123456&mode=preview"
        let html = generatedHTML(
            text: text,
            runs: [attributeRun(for: text, link: href)]
        )
        let target = NoteLinkTarget(
            markdownPath: "../EndMyopia/Preventing The Bad Plateau.md",
            obsidianReference: "iCloud/EndMyopia/Preventing The Bad Plateau",
            title: "Preventing The Bad Plateau"
        )
        let note = makeNote(htmlBody: html)

        XCTAssertTrue(html.contains("identifier=x-coredata://ABCDEF-123456&amp;mode=preview"))
        XCTAssertTrue(
            note.toMarkdown(
                flavor: .obsidian,
                noteLinkTargets: ["x-coredata://ABCDEF-123456": target]
            ).contains("[[iCloud/EndMyopia/Preventing The Bad Plateau|Plateau note]]")
        )
    }

    func testAppleNotesChecklistStateIsPreservedInMarkdown() throws {
        let note = makeNote(
            htmlBody: """
            <html><body>
            <ul style='list-style-type: none;'>
            <li data-indent='0' data-list-type='103'>☑ Export locked notes cleanly</li>
            <li data-indent='0' data-list-type='103'>☐ Add task-list syntax later</li>
            </ul>
            </body></html>
            """
        )

        let markdown = note.toMarkdown(flavor: .obsidian)

        XCTAssertTrue(markdown.contains("- ☑ Export locked notes cleanly"))
        XCTAssertTrue(markdown.contains("- ☐ Add task-list syntax later"))
    }

    func testOrderedListNumbersItemsInSourceOrder() throws {
        let note = makeNote(
            htmlBody: """
            <html><body>
            <ol>
            <li data-indent='0' data-list-type='102'>First</li>
            <li data-indent='0' data-list-type='102'>Second</li>
            <li data-indent='0' data-list-type='102'>Third</li>
            </ol>
            </body></html>
            """
        )

        let markdown = note.toMarkdown(flavor: .obsidian)

        XCTAssertEqual(listLines(in: markdown), ["1. First", "2. Second", "3. Third"])
    }

    func testNestedOrderedListsUseIndependentCounters() throws {
        let note = makeNote(
            htmlBody: """
            <html><body>
            <ol>
            <li data-indent='0' data-list-type='102'>First parent</li>
            <li data-indent='1' data-list-type='102'>First child</li>
            <li data-indent='1' data-list-type='102'>Second child</li>
            <li data-indent='0' data-list-type='102'>Second parent</li>
            <li data-indent='1' data-list-type='102'>New first child</li>
            </ol>
            </body></html>
            """
        )

        let markdown = note.toMarkdown(flavor: .obsidian)

        XCTAssertEqual(
            listLines(in: markdown),
            [
                "1. First parent",
                "    1. First child",
                "    2. Second child",
                "2. Second parent",
                "    1. New first child"
            ]
        )
    }

    func testSeparateOrderedListsRestartAtOne() throws {
        let note = makeNote(
            htmlBody: """
            <html><body>
            <ol>
            <li data-indent='0' data-list-type='102'>First list item</li>
            <li data-indent='0' data-list-type='102'>Second list item</li>
            </ol>
            Between lists<br>
            <ol>
            <li data-indent='0' data-list-type='102'>Restarted list item</li>
            </ol>
            </body></html>
            """
        )

        let markdown = note.toMarkdown(flavor: .obsidian)

        XCTAssertEqual(
            listLines(in: markdown),
            ["1. First list item", "2. Second list item", "1. Restarted list item"]
        )
        XCTAssertTrue(markdown.contains("Between lists"))
    }

    func testOrderedListPreservesInlineFormattingAndLinks() throws {
        let note = makeNote(
            htmlBody: """
            <html><body>
            <ol>
            <li data-indent='0' data-list-type='102'>Read the <strong>guide</strong> at <a href='https://example.com'>example</a></li>
            </ol>
            </body></html>
            """
        )

        let markdown = note.toMarkdown(flavor: .obsidian)

        XCTAssertEqual(
            listLines(in: markdown),
            ["1. Read the **guide** at [example](https://example.com)"]
        )
    }

    func testIndentedBulletListPreservesMarkersAndNesting() throws {
        let note = makeNote(
            htmlBody: """
            <html><body>
            <ul>
            <li data-indent='0' data-list-type='100'>Parent bullet</li>
            <li data-indent='1' data-list-type='100'>Child bullet</li>
            <li data-indent='0' data-list-type='100'>Second parent bullet</li>
            </ul>
            </body></html>
            """
        )

        let markdown = note.toMarkdown(flavor: .obsidian)

        XCTAssertEqual(
            listLines(in: markdown),
            ["- Parent bullet", "    - Child bullet", "- Second parent bullet"]
        )
    }

    func testNestedListTypeChangeDoesNotResetParentCounter() throws {
        let note = makeNote(
            htmlBody: """
            <html><body>
            <ol>
            <li data-indent='0' data-list-type='102'>First parent</li>
            <ol>
            <li data-indent='1' data-list-type='102'>Numbered child</li>
            </ol>
            <ul>
            <li data-indent='1' data-list-type='100'>Bullet child</li>
            </ul>
            <li data-indent='0' data-list-type='102'>Second parent</li>
            </ol>
            </body></html>
            """
        )

        let markdown = note.toMarkdown(flavor: .obsidian)

        XCTAssertEqual(
            listLines(in: markdown),
            [
                "1. First parent",
                "    1. Numbered child",
                "    - Bullet child",
                "2. Second parent"
            ]
        )
    }

    private func listLines(in markdown: String) -> [String] {
        markdown.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.range(of: #"^(?:-|\d+\.)\s"#, options: .regularExpression) != nil
        }
    }

    private func createModernNotesDatabase(at databaseURL: URL, additionalSQL: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "AppleNotesExporterTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not create synthetic Notes database"
            ])
        }
        defer { sqlite3_close(db) }

        try executeSQL(
            """
            CREATE TABLE Z_PRIMARYKEY (Z_NAME TEXT, Z_ENT INTEGER);
            INSERT INTO Z_PRIMARYKEY (Z_NAME, Z_ENT) VALUES
                ('ICNote', 1),
                ('ICAttachment', 2),
                ('ICAccount', 3),
                ('ICFolder', 4);

            CREATE TABLE ZICNOTEDATA (ZNOTE INTEGER, ZDATA BLOB);

            CREATE TABLE ZICCLOUDSYNCINGOBJECT (
                Z_PK INTEGER PRIMARY KEY,
                Z_ENT INTEGER,
                ZIDENTIFIER TEXT,
                ZNAME TEXT,
                ZTITLE TEXT,
                ZTITLE1 TEXT,
                ZTITLE2 TEXT,
                ZCREATIONDATE1 REAL,
                ZMODIFICATIONDATE1 REAL,
                ZFOLDER INTEGER,
                ZOWNER INTEGER,
                ZACCOUNT2 INTEGER,
                ZPARENT INTEGER,
                ZMARKEDFORDELETION INTEGER,
                ZSERVERRECORDDATA BLOB,
                ZTYPEUTI TEXT,
                ZFILENAME TEXT,
                ZMEDIA INTEGER,
                ZNOTE INTEGER,
                ZPARENTATTACHMENT INTEGER,
                ZATTACHMENT INTEGER,
                ZMERGEABLEDATA BLOB,
                ZALTTEXT TEXT,
                ZURLSTRING TEXT,
                ZTOKENCONTENTIDENTIFIER TEXT,
                ZFALLBACKIMAGEGENERATION TEXT,
                ZFALLBACKPDFGENERATION TEXT,
                ZHEIGHT INTEGER,
                ZWIDTH INTEGER
            );
            """,
            in: db
        )
        try executeSQL(additionalSQL, in: db)
    }

    private func executeSQL(_ sql: String, in db: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQLite error"
            throw NSError(domain: "AppleNotesExporterTests", code: Int(result), userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }

    private func generatedHTML(text: String, runs: [AttributeRun]) -> String {
        var note = Note()
        note.noteText = text
        note.attributeRun = runs
        return NoteHTMLGenerator(database: nil).generateHTML(from: note)
    }

    private func attributeRun(
        for text: String,
        link: String = "",
        paragraphStyle: ParagraphStyle? = nil
    ) -> AttributeRun {
        var run = AttributeRun()
        run.length = Int32(text.utf16.count)
        run.link = link
        if let paragraphStyle {
            run.paragraphStyle = paragraphStyle
        }
        return run
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
