//
//  SyncManifest.swift
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

import Foundation

/// Reject redirected output paths before filesystem mutations.
/// This is a preflight guard, not protection against concurrent filesystem tampering.
enum ExportWriteBoundary {
    struct UnsafePath: LocalizedError {
        var errorDescription: String? {
            "Export stopped: an output path escapes the selected folder or uses a filesystem link."
        }
    }

    static func validate(_ target: URL, root: URL) throws {
        // A symlink followed by ".." can resolve differently at write time.
        // Inspect the original components before Foundation collapses them.
        guard target.isFileURL, root.isFileURL,
              !target.pathComponents.contains(".."),
              !root.pathComponents.contains("..") else { throw UnsafePath() }
        let base = root.standardizedFileURL
        let destination = target.standardizedFileURL
        let baseParts = base.pathComponents
        let parts = destination.pathComponents
        guard parts.count >= baseParts.count,
              Array(parts.prefix(baseParts.count)) == baseParts else { throw UnsafePath() }

        // Check each existing component, including dangling symlinks and the root.
        var current = base
        let suffix = Array(parts.dropFirst(baseParts.count))
        for component in [String?](arrayLiteral: nil) + suffix.map({ Optional($0) }) {
            if let component { current.appendPathComponent(component) }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    throw UnsafePath()
                }
                if attributes[.type] as? FileAttributeType == .typeRegular,
                   let links = attributes[.referenceCount] as? NSNumber, links.intValue > 1 {
                    throw UnsafePath()
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // New directories and output files are allowed.
            }
        }
        let resolvedBase = base.resolvingSymlinksInPath().pathComponents
        let resolvedTarget = destination.resolvingSymlinksInPath().pathComponents
        guard resolvedTarget.count >= resolvedBase.count,
              Array(resolvedTarget.prefix(resolvedBase.count)) == resolvedBase else { throw UnsafePath() }
    }
}

// MARK: - Sync Manifest

enum ExportPathIdentity {
    // Conservatively avoid aliases even when exporting onto a case-sensitive volume.
    static func key(_ path: String) -> String {
        (path as NSString).standardizingPath.precomposedStringWithCanonicalMapping.lowercased()
    }
}

enum MarkdownRenderer {
    static let currentVersion = "markdown-v2"
}

struct SyncManifest: Codable {
    static let filename = "AppleNotesExportSyncWatermark.json"
    static let currentVersion = 1

    var version: Int = SyncManifest.currentVersion
    var lastSync: Date
    var notes: [String: SyncedNoteEntry]
    var collisionLinkRefreshPending: Bool?

    struct SyncedNoteEntry: Codable {
        var modificationDate: Date
        var exportedPath: String
        /// Relative paths to exported attachment files for this note
        var attachmentPaths: [String]
        /// Export settings that materially affect rendered output.
        var exportFingerprint: String?
        /// Stable note-content fingerprint used when Apple Notes timestamps are unreliable.
        var contentFingerprint: String?
        /// Markdown renderer used for the most recent successful Markdown export.
        var markdownRendererVersion: String?
    }

    struct MarkdownRendererRefreshPlanItem: Equatable {
        let noteId: String
        let noteTitle: String
        let exportedPath: String
    }

    // MARK: - Factory

    static func empty() -> SyncManifest {
        SyncManifest(lastSync: Date(), notes: [:])
    }

    // MARK: - Persistence

    /// Load manifest from a directory, returns nil if not found or unreadable
    static func load(from directory: URL) -> SyncManifest? {
        let fileURL = directory.appendingPathComponent(filename)
        guard (try? ExportWriteBoundary.validate(fileURL, root: directory)) != nil else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(SyncManifest.self, from: data)
    }

    /// Save manifest to a directory (atomic write)
    func save(to directory: URL) throws {
        let fileURL = directory.appendingPathComponent(SyncManifest.filename)
        try ExportWriteBoundary.validate(fileURL, root: directory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Sync Logic

    var collidingNoteIDs: Set<String> {
        let groups = Swift.Dictionary(grouping: notes.keys) { ExportPathIdentity.key(notes[$0]!.exportedPath) }
        return Set(groups.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    /// Determine which notes need to be exported (new or modified since last sync)
    func notesNeedingExport(
        from notes: [NotesNote],
        exportFingerprint: String? = nil,
        contentFingerprint: (NotesNote) -> String? = { _ in nil },
        acceptedContentFingerprints: (NotesNote) -> Set<String>? = { _ in nil },
        markdownRendererRefreshVersion: String? = nil
    ) -> [NotesNote] {
        let collisions = collidingNoteIDs
        return notes.filter { note in
            if collisions.contains(note.id) { return true }
            guard let entry = self.notes[note.id] else {
                // Note not in manifest — it's new
                return true
            }
            if entry.exportFingerprint != exportFingerprint {
                return true
            }
            let currentContentFingerprint = contentFingerprint(note)
            if let acceptedFingerprints = acceptedContentFingerprints(note) {
                guard let entryContentFingerprint = entry.contentFingerprint,
                      acceptedFingerprints.contains(entryContentFingerprint) else {
                    return true
                }
            } else if entry.contentFingerprint != currentContentFingerprint {
                return true
            }
            if let markdownRendererRefreshVersion,
               entry.markdownRendererVersion != markdownRendererRefreshVersion {
                return true
            }
            // Note exists — check if it's been modified since last export
            // Use 0.001s tolerance to avoid floating-point precision false positives
            return note.modificationDate.timeIntervalSince1970 - entry.modificationDate.timeIntervalSince1970 > 0.001
        }
    }

    /// Get the previously exported path for a note (for overwrite-in-place)
    func existingPath(for noteId: String) -> String? {
        return notes[noteId]?.exportedPath
    }

    func markdownRendererRefreshPlan(
        from notes: [NotesNote],
        currentVersion: String
    ) -> [MarkdownRendererRefreshPlanItem] {
        notes.compactMap { note in
            guard let entry = self.notes[note.id],
                  entry.markdownRendererVersion != currentVersion else {
                return nil
            }
            return MarkdownRendererRefreshPlanItem(
                noteId: note.id,
                noteTitle: note.title,
                exportedPath: entry.exportedPath
            )
        }.sorted { lhs, rhs in
            lhs.exportedPath.localizedStandardCompare(rhs.exportedPath) == .orderedAscending
        }
    }

    // MARK: - Mutation

    /// Record a successfully exported note
    mutating func recordExport(
        noteId: String,
        modificationDate: Date,
        exportedPath: String,
        attachmentPaths: [String] = [],
        exportFingerprint: String? = nil,
        contentFingerprint: String? = nil,
        markdownRendererVersion: String? = nil
    ) {
        notes[noteId] = SyncedNoteEntry(
            modificationDate: modificationDate,
            exportedPath: exportedPath,
            attachmentPaths: attachmentPaths,
            exportFingerprint: exportFingerprint,
            contentFingerprint: contentFingerprint,
            markdownRendererVersion: markdownRendererVersion
        )
        lastSync = Date()
    }
}
