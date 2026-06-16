//
//  ExportViewModel.swift
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
import SwiftUI
import OSLog
import HtmlToPdf
import CryptoKit

// MARK: - Export Errors

enum ExportError: Error, LocalizedError {
    case pdfGenerationTimeout

    var errorDescription: String? {
        switch self {
        case .pdfGenerationTimeout:
            return "PDF generation timed out after 60 seconds. This note may contain many large images or corrupted attachments."
        }
    }
}

// MARK: - Sync Manifest Actor

/// Thread-safe wrapper for SyncManifest mutations during concurrent export
actor SyncManifestTracker {
    private var manifest: SyncManifest

    init(manifest: SyncManifest) {
        self.manifest = manifest
    }

    func recordExport(
        noteId: String,
        modificationDate: Date,
        exportedPath: String,
        attachmentPaths: [String] = [],
        exportFingerprint: String? = nil,
        contentFingerprint: String? = nil
    ) {
        manifest.recordExport(
            noteId: noteId,
            modificationDate: modificationDate,
            exportedPath: exportedPath,
            attachmentPaths: attachmentPaths,
            exportFingerprint: exportFingerprint,
            contentFingerprint: contentFingerprint
        )
    }

    func getManifest() -> SyncManifest {
        return manifest
    }
}

// MARK: - Export Progress

struct ExportProgress: Equatable {
    var current: Int = 0
    var total: Int = 0
    var message: String = ""
    var percentage: Double {
        guard total > 0 else { return 0 }
        return Double(current) / Double(total)
    }
}

// MARK: - Progress Tracker Actor

actor ExportProgressTracker {
    private var completedCount: Int = 0
    private var failedNotesCount: Int = 0
    private var failedAttachmentsCount: Int = 0

    func noteCompleted() -> Int {
        completedCount += 1
        return completedCount
    }

    func noteFailed() {
        failedNotesCount += 1
    }

    func attachmentFailed() {
        failedAttachmentsCount += 1
    }

    func getStats() -> (completed: Int, failedNotes: Int, failedAttachments: Int) {
        return (completedCount, failedNotesCount, failedAttachmentsCount)
    }
}

// MARK: - Export Statistics

struct ExportStatistics: Equatable {
    var successfulNotes: Int = 0
    var failedNotes: Int = 0
    var failedAttachments: Int = 0
    var passwordProtectedNoteTitles: [String] = []
    var completionDate: Date = Date()
}

private struct ExportPlanEntry: Sendable {
    let folderURL: URL
    let fileURL: URL
    let uniqueBaseName: String
    let noteIdentifier: String?
    let noteTitle: String
}

private struct StaleExportArtifacts: Sendable {
    let fileURL: URL
    let attachmentURLs: [URL]
}

struct PasswordProtectedNoteReport: Equatable {
    let titles: [String]

    var count: Int {
        titles.count
    }

    var hasNotes: Bool {
        !titles.isEmpty
    }

    var summary: String {
        "\(count) locked/password-protected note\(count == 1 ? "" : "s") found. Body content is unavailable until unlocked in Apple Notes."
    }

    static func make(for notes: [NotesNote]) -> PasswordProtectedNoteReport {
        let titles = notes
            .filter(\.isPasswordProtected)
            .map(\.title)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return PasswordProtectedNoteReport(titles: titles)
    }
}

enum NoteContentFingerprint {
    static func value(for note: NotesNote) -> String {
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
}

// MARK: - Export State

enum ExportState: Equatable {
    case idle
    case exporting(ExportProgress)
    case completed(ExportStatistics)
    case cancelled
    case error(String)

    var isExporting: Bool {
        if case .exporting = self { return true }
        return false
    }
}

// MARK: - Export ViewModel

@MainActor
class ExportViewModel: ObservableObject {
    // MARK: - Published Properties

    @Published var exportState: ExportState = .idle
    @Published var shouldCancel: Bool = false
    @Published var exportLog: [String] = []
    @Published var configurations: ExportConfigurations

    // MARK: - Statistics Tracking

    private var failedNotesCount: Int = 0
    private var failedAttachmentsCount: Int = 0

    // MARK: - Concurrency Settings

    /// Calculate optimal number of concurrent exports based on system resources
    /// Formula: min(core_count, total_ram_gb_rounded_up / 2)
    /// This balances CPU availability with memory constraints
    private var maxConcurrentExports: Int {
        let coreCount = ProcessInfo.processInfo.processorCount

        // Get total physical memory in bytes
        let totalMemory = ProcessInfo.processInfo.physicalMemory

        // Convert to gigabytes and round up to nearest gigabyte
        let totalMemoryGB = Int(ceil(Double(totalMemory) / 1_073_741_824.0))

        // Calculate memory-based limit (half of available RAM in GB)
        let memoryLimit = max(1, totalMemoryGB / 2)

        // Take the minimum to respect both CPU and memory constraints
        let optimal = min(coreCount, memoryLimit)

        // Ensure at least 1 concurrent task, cap at 16 for safety
        return max(1, min(optimal, 16))
    }

    private let logLock = NSLock()  // Thread-safe logging

    // MARK: - Dependencies

    private let repository: NotesRepository
    private let databasePath: String

    // MARK: - Initialization

    init(repository: NotesRepository = DatabaseNotesRepository(), databasePath: String = "\(NSHomeDirectory())/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite") {
        self.repository = repository
        self.databasePath = databasePath
        self.configurations = ExportConfigurations.load()
    }

    // MARK: - Configuration Management

    func saveConfigurations() {
        configurations.save()
    }

    // MARK: - Export Operations

    /// Export notes to the specified output directory
    func exportNotes(
        _ notes: [NotesNote],
        toDirectory outputURL: URL,
        format: ExportFormat,
        includeAttachments: Bool = true
    ) async {
        // Reset state and clear log for new export
        shouldCancel = false
        exportLog = []
        failedNotesCount = 0
        failedAttachmentsCount = 0
        let startTime = Date()

        do {
            let exportableNotes = try await notesExcludingRecentlyDeleted(notes)
            let currentExportNoteIDs = Set(exportableNotes.map(\.id))
            let passwordProtectedReport = PasswordProtectedNoteReport.make(for: exportableNotes)
            let skippedRecentlyDeletedCount = notes.count - exportableNotes.count
            if skippedRecentlyDeletedCount > 0 {
                log("Skipping \(skippedRecentlyDeletedCount) note\(skippedRecentlyDeletedCount == 1 ? "" : "s") in Recently Deleted")
            }
            logPasswordProtectedNoteReport(passwordProtectedReport)

            // Incremental sync: load existing manifest and filter to new/changed notes
            let isSync = configurations.incrementalSync
            let existingManifest = isSync ? SyncManifest.load(from: outputURL) : nil
            let syncTracker: SyncManifestTracker?
            let exportFingerprint = currentExportFingerprint(for: format)
            let contentFingerprint: (NotesNote) -> String? = { note in
                self.noteContentFingerprint(note)
            }

            let notesToExport: [NotesNote]
            if isSync, let manifest = existingManifest {
                var filteredNotes = manifest.notesNeedingExport(
                    from: exportableNotes,
                    exportFingerprint: exportFingerprint,
                    contentFingerprint: contentFingerprint
                )
                let settingsDrivenCount = exportableNotes.countMatchingExportFingerprintChange(
                    manifest: manifest,
                    exportFingerprint: exportFingerprint
                )
                if format.fileExtension == ExportFormat.markdown.fileExtension {
                    let migrationNotes = notesNeedingMarkdownCleanup(
                        from: exportableNotes,
                        manifest: manifest,
                        outputRootURL: outputURL
                    )
                    let existingIDs = Set(filteredNotes.map(\.id))
                    filteredNotes.append(contentsOf: migrationNotes.filter { !existingIDs.contains($0.id) })
                }
                let missingArtifactNotes = notesMissingExportArtifacts(
                    from: exportableNotes,
                    manifest: manifest,
                    outputRootURL: outputURL
                )
                let filteredIDs = Set(filteredNotes.map(\.id))
                filteredNotes.append(contentsOf: missingArtifactNotes.filter { !filteredIDs.contains($0.id) })
                notesToExport = filteredNotes
                // Start from existing manifest so we preserve entries for unchanged notes
                syncTracker = SyncManifestTracker(manifest: manifest)
                if notesToExport.isEmpty {
                    var updatedManifest = manifest
                    let removedStaleExports = try removeManifestEntriesNotInCurrentExportSet(
                        from: &updatedManifest,
                        currentNoteIDs: currentExportNoteIDs,
                        outputRootURL: outputURL
                    )
                    if removedStaleExports > 0 {
                        log("✓ Removed \(removedStaleExports) stale export\(removedStaleExports == 1 ? "" : "s")")
                    }
                    let removedUntrackedArtifacts = try removeUntrackedExportArtifacts(
                        preserving: updatedManifest,
                        outputRootURL: outputURL
                    )
                    if removedUntrackedArtifacts.files > 0 || removedUntrackedArtifacts.directories > 0 {
                        log("✓ Removed \(removedUntrackedArtifacts.files) untracked export file\(removedUntrackedArtifacts.files == 1 ? "" : "s") and \(removedUntrackedArtifacts.directories) orphan attachment folder\(removedUntrackedArtifacts.directories == 1 ? "" : "s")")
                    }
                    log("✓ All notes are up to date, nothing to export")
                    exportState = .completed(ExportStatistics(
                        successfulNotes: 0,
                        failedNotes: 0,
                        failedAttachments: 0,
                        passwordProtectedNoteTitles: passwordProtectedReport.titles,
                        completionDate: Date()
                    ))
                    // Still update lastSync timestamp
                    updatedManifest.lastSync = Date()
                    try updatedManifest.save(to: outputURL)
                    return
                }
                if settingsDrivenCount > 0 {
                    log("Incremental sync: export settings changed, validating \(notesToExport.count) notes of \(exportableNotes.count) total")
                } else {
                    log("Incremental sync: \(notesToExport.count) new/changed notes of \(exportableNotes.count) total")
                }
            } else {
                notesToExport = exportableNotes
                syncTracker = isSync ? SyncManifestTracker(manifest: .empty()) : nil
            }

            // Start exporting
            exportState = .exporting(ExportProgress(
                current: 0,
                total: notesToExport.count,
                message: isSync ? "Starting incremental sync..." : "Starting export..."
            ))

            // Group changed notes for actual export work, but build link targets from the full selected set.
            let hierarchy = try await organizeNotesByHierarchy(notesToExport)
            let allSelectedHierarchy = try await organizeNotesByHierarchy(exportableNotes)

            // Create all directory structure upfront
            for (accountName, folders) in hierarchy {
                let accountURL = outputURL.appendingPathComponent(sanitizeFilename(accountName))
                try FileManager.default.createDirectory(at: accountURL, withIntermediateDirectories: true)

                for (folderPath, _) in folders {
                    let folderURL = accountURL.appendingPathComponent(folderPath)
                    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                }
            }

            let notesWithPaths = flattenNotesWithPaths(from: hierarchy, outputURL: outputURL)
            let allSelectedNotesWithPaths = flattenNotesWithPaths(from: allSelectedHierarchy, outputURL: outputURL)

            let exportPlan = buildExportPlan(
                for: allSelectedNotesWithPaths,
                format: format,
                rootURL: outputURL,
                syncManifest: existingManifest,
                isSync: isSync
            )

            // Check if we should concatenate all notes into a single file
            if configurations.concatenateOutput {
                try await exportNotesConcatenated(
                    notesWithPaths,
                    exportPlan: exportPlan,
                    format: format,
                    includeAttachments: includeAttachments,
                    totalNotes: notesToExport.count,
                    outputURL: outputURL,
                    startTime: startTime
                )
            } else {
                // Export notes concurrently (default behavior)
                try await exportNotesConcurrently(
                    notesWithPaths,
                    exportPlan: exportPlan,
                    format: format,
                    includeAttachments: includeAttachments,
                    totalNotes: notesToExport.count,
                    startTime: startTime,
                    syncTracker: syncTracker,
                    syncManifest: existingManifest,
                    outputRootURL: isSync ? outputURL : nil,
                    rootURL: outputURL,
                    exportFingerprint: exportFingerprint
                )
            }

            // Check if export was cancelled before marking as completed
            guard !shouldCancel else {
                // State already set to .cancelled in exportNotesConcurrently
                return
            }

            // Set folder timestamps based on their notes
            try await setFolderTimestamps(hierarchy: hierarchy, outputURL: outputURL)

            // Save sync manifest if incremental sync is enabled
            if let syncTracker = syncTracker {
                var finalManifest = await syncTracker.getManifest()
                let removedStaleExports = try removeManifestEntriesNotInCurrentExportSet(
                    from: &finalManifest,
                    currentNoteIDs: currentExportNoteIDs,
                    outputRootURL: outputURL
                )
                if removedStaleExports > 0 {
                    log("✓ Removed \(removedStaleExports) stale export\(removedStaleExports == 1 ? "" : "s")")
                }
                let removedUntrackedArtifacts = try removeUntrackedExportArtifacts(
                    preserving: finalManifest,
                    outputRootURL: outputURL
                )
                if removedUntrackedArtifacts.files > 0 || removedUntrackedArtifacts.directories > 0 {
                    log("✓ Removed \(removedUntrackedArtifacts.files) untracked export file\(removedUntrackedArtifacts.files == 1 ? "" : "s") and \(removedUntrackedArtifacts.directories) orphan attachment folder\(removedUntrackedArtifacts.directories == 1 ? "" : "s")")
                }
                try finalManifest.save(to: outputURL)
                log("✓ Sync manifest saved")
            }

            // Export completed successfully
            let successfulNotes = notesToExport.count - failedNotesCount
            exportState = .completed(ExportStatistics(
                successfulNotes: successfulNotes,
                failedNotes: failedNotesCount,
                failedAttachments: failedAttachmentsCount,
                passwordProtectedNoteTitles: passwordProtectedReport.titles,
                completionDate: Date()
            ))
            Logger.noteExport.info("Export completed: \(successfulNotes) successful, \(self.failedNotesCount) failed notes, \(self.failedAttachmentsCount) failed attachments, \(passwordProtectedReport.count) locked/password-protected notes")

        } catch {
            exportState = .error(error.localizedDescription)
            Logger.noteExport.error("Export failed: \(error.localizedDescription)")
        }
    }

    /// Export notes concurrently using TaskGroup
    private func exportNotesConcurrently(
        _ notesWithPaths: [(note: NotesNote, folderURL: URL)],
        exportPlan: [String: ExportPlanEntry],
        format: ExportFormat,
        includeAttachments: Bool,
        totalNotes: Int,
        startTime: Date,
        syncTracker: SyncManifestTracker? = nil,
        syncManifest: SyncManifest? = nil,
        outputRootURL: URL? = nil,
        rootURL: URL,
        exportFingerprint: String?
    ) async throws {
        let tracker = ExportProgressTracker()

        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = notesWithPaths.makeIterator()
            var activeTaskCount = 0

            // Launch initial batch of concurrent exports
            while activeTaskCount < maxConcurrentExports, let noteWithPath = iterator.next() {
                group.addTask {
                    await self.exportNoteConcurrently(
                        noteWithPath.note,
                        toDirectory: noteWithPath.folderURL,
                        format: format,
                        includeAttachments: includeAttachments,
                        tracker: tracker,
                        syncTracker: syncTracker,
                        overrideRelativePath: syncManifest?.existingPath(for: noteWithPath.note.id),
                        previousSyncEntry: syncManifest?.notes[noteWithPath.note.id],
                        outputRootURL: outputRootURL,
                        rootURL: rootURL,
                        planEntry: exportPlan[noteWithPath.note.id],
                        exportPlan: exportPlan,
                        exportFingerprint: exportFingerprint
                    )
                }
                activeTaskCount += 1
            }

            // Process completed tasks and launch new ones
            for try await _ in group {
                // Check for cancellation
                if shouldCancel {
                    group.cancelAll()
                    exportState = .cancelled
                    Logger.noteExport.info("Export cancelled by user")
                    return
                }

                // Update progress
                let stats = await tracker.getStats()
                let completed = stats.completed

                // Update stats on main actor
                failedNotesCount = stats.failedNotes
                failedAttachmentsCount = stats.failedAttachments

                // Calculate time remaining
                let elapsedTime = Date().timeIntervalSince(startTime)
                let timePerNote = elapsedTime / Double(completed)
                let remainingNotes = totalNotes - completed
                let estimatedRemaining = timePerNote * Double(remainingNotes)

                // Update progress message
                let message = completed >= 10
                    ? "Exporting notes \(completed) of \(totalNotes) (\(formatTimeRemaining(estimatedRemaining)) remaining)"
                    : "Exporting notes \(completed) of \(totalNotes)"

                exportState = .exporting(ExportProgress(
                    current: completed,
                    total: totalNotes,
                    message: message
                ))

                // Launch next task if available
                if let noteWithPath = iterator.next() {
                    group.addTask {
                        await self.exportNoteConcurrently(
                            noteWithPath.note,
                            toDirectory: noteWithPath.folderURL,
                            format: format,
                            includeAttachments: includeAttachments,
                            tracker: tracker,
                            syncTracker: syncTracker,
                            overrideRelativePath: syncManifest?.existingPath(for: noteWithPath.note.id),
                            previousSyncEntry: syncManifest?.notes[noteWithPath.note.id],
                            outputRootURL: outputRootURL,
                            rootURL: rootURL,
                            planEntry: exportPlan[noteWithPath.note.id],
                            exportPlan: exportPlan,
                            exportFingerprint: exportFingerprint
                        )
                    }
                }
            }
        }
    }

    /// Export all notes concatenated into a single file
    private func exportNotesConcatenated(
        _ notesWithPaths: [(note: NotesNote, folderURL: URL)],
        exportPlan: [String: ExportPlanEntry],
        format: ExportFormat,
        includeAttachments: Bool,
        totalNotes: Int,
        outputURL: URL,
        startTime: Date
    ) async throws {
        var contentParts: [String] = []

        for (index, noteWithPath) in notesWithPaths.enumerated() {
            guard !shouldCancel else {
                exportState = .cancelled
                Logger.noteExport.info("Export cancelled by user")
                return
            }

            let note = noteWithPath.note

            exportState = .exporting(ExportProgress(
                current: index,
                total: totalNotes,
                message: "Processing note \(index + 1) of \(totalNotes)..."
            ))

            do {
                // Export attachments if needed (into the output root directory)
                var attachmentPaths: [String: String] = [:]
                if includeAttachments && note.hasAttachments {
                    let tracker = ExportProgressTracker()
                    let baseFilename = note.sanitizedFileName
                    attachmentPaths = try await exportAttachmentsAndReturnPaths(
                        note.attachments,
                        toDirectory: outputURL,
                        noteBaseName: baseFilename,
                        noteTitle: note.title,
                        noteCreationDate: note.creationDate,
                        noteModificationDate: note.modificationDate,
                        tracker: tracker
                    )
                    let stats = await tracker.getStats()
                    failedAttachmentsCount += stats.failedAttachments
                }

                // Generate content for this note
                let content = try await generateContent(
                    for: note,
                    format: format,
                    attachmentPaths: attachmentPaths,
                    exportDirectory: outputURL,
                    rootURL: outputURL,
                    exportPlan: exportPlan
                )
                contentParts.append(content)
                log("✓ Processed note: \(note.title)")
            } catch {
                failedNotesCount += 1
                log("✗ Failed to process note '\(note.title)': \(error.localizedDescription)")
                Logger.noteExport.error("Failed to process note for concatenation: \(note.title) - \(error.localizedDescription)")
            }
        }

        guard !shouldCancel else {
            exportState = .cancelled
            return
        }

        // Join all content with format-appropriate separators
        let separator: String
        switch format {
        case .html:
            separator = "\n<hr style=\"page-break-after: always;\">\n"
        case .pdf:
            separator = "\n<hr style=\"page-break-after: always;\">\n"
        case .markdown:
            separator = "\n\n---\n\n"
        case .txt:
            separator = "\n\n" + String(repeating: "=", count: 72) + "\n\n"
        case .rtf:
            separator = "\n\\page\n"
        case .tex:
            separator = "\n\n\\newpage\n\n"
        }

        let concatenated = contentParts.joined(separator: separator)

        // Write the single concatenated file
        let filename = "Exported Notes.\(format.fileExtension)"
        let fileURL = outputURL.appendingPathComponent(filename)

        if format == .pdf {
            // For PDF, the concatenated content is HTML — render it
            let pdfConfig = configurations.pdf
            let pageSize = pdfConfig.pageSize.dimensions
            let margins = pdfConfig.htmlConfiguration.toPDFEdgeInsets()
            let pdfConfiguration = HtmlToPdf.PDFConfiguration(
                margins: margins,
                paperSize: CGSize(width: pageSize.width, height: pageSize.height)
            )

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await concatenated.print(to: fileURL, configuration: pdfConfiguration)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(totalNotes) * 60_000_000_000)
                    throw ExportError.pdfGenerationTimeout
                }
                try await group.next()
                group.cancelAll()
            }
        } else {
            try concatenated.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        log("✓ Exported concatenated file: \(filename)")
    }

    /// Export a single note concurrently (non-throwing wrapper for TaskGroup)
    private func exportNoteConcurrently(
        _ note: NotesNote,
        toDirectory directory: URL,
        format: ExportFormat,
        includeAttachments: Bool,
        tracker: ExportProgressTracker,
        syncTracker: SyncManifestTracker? = nil,
        overrideRelativePath: String? = nil,
        previousSyncEntry: SyncManifest.SyncedNoteEntry? = nil,
        outputRootURL: URL? = nil,
        rootURL: URL,
        planEntry: ExportPlanEntry? = nil,
        exportPlan: [String: ExportPlanEntry] = [:],
        exportFingerprint: String? = nil
    ) async {
        do {
            try await exportNoteSafely(
                note,
                toDirectory: directory,
                format: format,
                includeAttachments: includeAttachments,
                tracker: tracker,
                syncTracker: syncTracker,
                overrideRelativePath: overrideRelativePath,
                previousSyncEntry: previousSyncEntry,
                outputRootURL: outputRootURL,
                rootURL: rootURL,
                planEntry: planEntry,
                exportPlan: exportPlan,
                exportFingerprint: exportFingerprint
            )
            _ = await tracker.noteCompleted()
        } catch {
            await tracker.noteFailed()

            // Build detailed error message for user logs
            var errorDetails = [
                "Note: '\(note.title)'",
                "ID: \(note.id)",
                "Format: \(format.rawValue)",
                "Error: \(error.localizedDescription)"
            ]

            if let nsError = error as NSError? {
                errorDetails.append("Domain: \(nsError.domain)")
                errorDetails.append("Code: \(nsError.code)")

                if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    errorDetails.append("Underlying: \(underlyingError.localizedDescription)")
                }
            }

            let detailedMessage = "✗ Failed to export note - " + errorDetails.joined(separator: ", ")
            log(detailedMessage)
            Logger.noteExport.error("Failed to export note: \(errorDetails.joined(separator: ", "))")
        }
    }

    /// Export a single note to disk (thread-safe version for concurrent export)
    private func exportNoteSafely(
        _ note: NotesNote,
        toDirectory directory: URL,
        format: ExportFormat,
        includeAttachments: Bool,
        tracker: ExportProgressTracker,
        syncTracker: SyncManifestTracker? = nil,
        overrideRelativePath: String? = nil,
        previousSyncEntry: SyncManifest.SyncedNoteEntry? = nil,
        outputRootURL: URL? = nil,
        rootURL: URL,
        planEntry: ExportPlanEntry? = nil,
        exportPlan: [String: ExportPlanEntry] = [:],
        exportFingerprint: String? = nil
    ) async throws {
        // Check for cancellation before starting export
        try Task.checkCancellation()

        // Determine file URL — either overwrite at existing path (sync) or generate new
        let fileURL: URL
        let uniqueBaseName: String

        if let planEntry {
            fileURL = planEntry.fileURL
            uniqueBaseName = planEntry.uniqueBaseName
        } else if let relativePath = overrideRelativePath, let outputRootURL {
            // Sync mode: overwrite at previously exported path
            fileURL = outputRootURL.appendingPathComponent(relativePath)
            // Ensure parent directory exists (in case folder structure was deleted)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            uniqueBaseName = fileURL.deletingPathExtension().lastPathComponent
        } else {
            // Normal mode: generate unique filename
            let baseFilename: String
            if configurations.addDateToFilename {
                let formatter = DateFormatter()
                formatter.dateFormat = configurations.filenameDateFormat.rawValue
                let datePrefix = formatter.string(from: note.creationDate)
                baseFilename = "\(datePrefix) \(note.sanitizedFileName)"
            } else {
                baseFilename = note.sanitizedFileName
            }

            if outputRootURL != nil,
               let existingSyncFileURL = findExistingSyncFileURL(
                for: note,
                baseName: baseFilename,
                format: format,
                inDirectory: directory
               ) {
                fileURL = existingSyncFileURL
                uniqueBaseName = existingSyncFileURL.deletingPathExtension().lastPathComponent
            } else {
                let filename = generateUniqueFilename(
                    baseName: baseFilename,
                    extension: format.fileExtension,
                    inDirectory: directory
                )
                fileURL = directory.appendingPathComponent(filename)
                uniqueBaseName = filename.replacingOccurrences(of: ".\(format.fileExtension)", with: "")
            }
        }

        let staleArtifacts = staleExportArtifacts(
            previousEntry: previousSyncEntry,
            plannedFileURL: fileURL,
            noteDirectory: directory,
            rootURL: outputRootURL
        )

        // Export attachments before note content (required for HTML attachment path resolution)
        var attachmentPaths: [String: String] = [:]
        if includeAttachments && note.hasAttachments {
            // Check for cancellation before processing attachments
            try Task.checkCancellation()

            attachmentPaths = try await exportAttachmentsAndReturnPaths(
                note.attachments,
                toDirectory: directory,
                noteBaseName: uniqueBaseName,
                noteTitle: note.title,
                noteCreationDate: note.creationDate,
                noteModificationDate: note.modificationDate,
                tracker: tracker
            )
        }

        // Handle PDF export separately (binary format, requires WebKit)
        if format == .pdf {
            // Check for cancellation before expensive PDF generation
            try Task.checkCancellation()

            // Use PDF configuration
            let pdfConfig = configurations.pdf

            // Apply page size and margin configuration
            let pageSize = pdfConfig.pageSize.dimensions
            let margins = pdfConfig.htmlConfiguration.toPDFEdgeInsets()

            // Generate HTML with PDF-specific constraints
            let pageSizeCG = CGSize(width: pageSize.width, height: pageSize.height)
            let marginsNS = pdfConfig.htmlConfiguration.toNSEdgeInsets()

            let html = try await generateHTML(
                for: note,
                config: pdfConfig.htmlConfiguration,
                forPDF: true,
                attachmentPaths: attachmentPaths,
                exportDirectory: directory,
                pdfPageSize: pageSizeCG,
                pdfMargins: marginsNS
            )
            let pdfConfiguration = HtmlToPdf.PDFConfiguration(
                margins: margins,
                paperSize: pageSizeCG
            )

            // Add timeout for PDF generation to prevent infinite hangs on corrupted images
            // Notes with many images can take 30+ seconds to render
            // HEIC conversion to JPEG helps, but timeout still needed for truly corrupted files
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await html.print(to: fileURL, configuration: pdfConfiguration)
                }

                group.addTask {
                    // 60 second timeout - allows image-heavy notes to render while catching infinite hangs
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    throw ExportError.pdfGenerationTimeout
                }

                // Wait for first task to complete (either PDF finishes or timeout)
                try await group.next()
                group.cancelAll()
            }

            log("✓ Exported PDF: \(note.title)")
        } else {
            // Generate content based on format
            let content = try await generateContent(
                for: note,
                format: format,
                attachmentPaths: attachmentPaths,
                exportDirectory: directory,
                rootURL: rootURL,
                exportPlan: exportPlan
            )

            if outputRootURL != nil,
               FileManager.default.fileExists(atPath: fileURL.path),
               let existingContent = try? String(contentsOf: fileURL, encoding: .utf8),
               existingContent == content {
                log("✓ Note unchanged: \(note.title)")
            } else {
                // Write to file
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
                log("✓ Exported note: \(note.title) -> \(fileURL.path)")
            }
        }

        // Set file timestamps to match note's creation and modification dates
        try setFileTimestamps(fileURL, creationDate: note.creationDate, modificationDate: note.modificationDate)

        let attachmentRelPaths = attachmentPaths.values.map { path in
            // attachmentPaths values are relative to the note's directory, make them relative to root
            let noteDir = outputRootURL.map { directory.path.replacingOccurrences(of: $0.path + "/", with: "") } ?? ""
            return noteDir.isEmpty ? path : "\(noteDir)/\(path)"
        }

        // Record in sync manifest if tracking
        if let syncTracker = syncTracker, let rootURL = outputRootURL {
            // Compute relative path from output root
            let relativePath = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            await syncTracker.recordExport(
                noteId: note.id,
                modificationDate: note.modificationDate,
                exportedPath: relativePath,
                attachmentPaths: attachmentRelPaths,
                exportFingerprint: exportFingerprint,
                contentFingerprint: noteContentFingerprint(note)
            )
        }

        try removeStaleExportArtifacts(
            staleArtifacts,
            preservingFilePaths: exportPlan.values.map { $0.fileURL },
            preservingAttachmentRelativePaths: attachmentRelPaths,
            rootURL: outputRootURL
        )
    }

    /// Export attachments for a note and return a map of attachment IDs to relative paths
    private func exportAttachmentsAndReturnPaths(
        _ attachments: [NotesAttachment],
        toDirectory directory: URL,
        noteBaseName: String,
        noteTitle: String,
        noteCreationDate: Date,
        noteModificationDate: Date,
        tracker: ExportProgressTracker
    ) async throws -> [String: String] {
        var attachmentPaths: [String: String] = [:]

        // Filter out non-file attachments (inline content embedded in note)
        // Note: com.apple.paper, com.apple.drawing, and com.apple.drawing.2 are NOT filtered
        // because they are drawing/sketch attachments with fallback images that should be exported
        let nonFileAttachmentPrefixes = [
            "com.apple.notes.table",                    // Tables
            "com.apple.notes.inlinetextattachment",     // Hashtags, calculations, etc.
            "com.apple.notes.inlinehashtagattachment",  // Hashtags (legacy)
            "com.apple.notes.inlinementionattachment",  // Mentions
            "public.url"                                // URLs
        ]

        let fileAttachments = attachments.filter { attachment in
            !nonFileAttachmentPrefixes.contains { prefix in
                attachment.typeUTI.hasPrefix(prefix)
            }
        }

        // Skip if no file attachments to export
        guard !fileAttachments.isEmpty else {
            return attachmentPaths
        }

        // Create attachments subfolder using the unique note base name
        let attachmentsURL = directory.appendingPathComponent("\(noteBaseName) (Attachments)")
        try FileManager.default.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)

        // Track used filenames to handle collisions
        var usedFilenames: [String: Int] = [:]

        // Export each attachment
        for attachment in fileAttachments {
            // Check for cancellation before processing each attachment
            try Task.checkCancellation()

            do {
                // Fetch attachment data from repository
                let data = try await repository.fetchAttachment(id: attachment.id)

                // Determine base filename
                // If attachment.filename is not available, try to get it from the database
                let rawFilename: String
                if let filename = attachment.filename {
                    rawFilename = filename
                } else if let fetchedFilename = await repository.fetchAttachmentFilename(id: attachment.id) {
                    rawFilename = fetchedFilename
                } else {
                    // Final fallback to UUID with extension
                    rawFilename = attachment.id
                }

                let baseFilename = normalizedAttachmentFilename(rawFilename, for: attachment)

                // Handle filename collisions by adding a counter suffix
                let finalFilename: String
                if let count = usedFilenames[baseFilename] {
                    // This filename has been used before, add a counter
                    let (name, ext) = splitFilename(baseFilename)
                    finalFilename = "\(name) (\(count + 1)).\(ext)"
                    usedFilenames[baseFilename] = count + 1
                } else {
                    // First time using this filename
                    finalFilename = baseFilename
                    usedFilenames[baseFilename] = 1
                }

                let fileURL = attachmentsURL.appendingPathComponent(finalFilename)

                // Write attachment to disk
                try data.write(to: fileURL)

                // Set attachment timestamps to match note's dates
                try setFileTimestamps(fileURL, creationDate: noteCreationDate, modificationDate: noteModificationDate)

                log("✓ Exported attachment: \(finalFilename) for note '\(noteTitle)'")

                // Store relative path for this attachment
                let relativePath = "\(noteBaseName) (Attachments)/\(finalFilename)"
                attachmentPaths[attachment.id] = relativePath

            } catch {
                await tracker.attachmentFailed()

                // Build detailed error message for user logs
                var errorDetails = [
                    "Attachment ID: \(attachment.id)",
                    "Type: \(attachment.typeUTI)",
                    "Note: '\(noteTitle)'"
                ]

                if let filename = attachment.filename {
                    errorDetails.append("Filename: \(filename)")
                }

                // Include detailed error information
                errorDetails.append("Error: \(error.localizedDescription)")

                if let nsError = error as NSError? {
                    errorDetails.append("Domain: \(nsError.domain)")
                    errorDetails.append("Code: \(nsError.code)")

                    if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                        errorDetails.append("Underlying: \(underlyingError.localizedDescription)")
                    }
                }

                let detailedMessage = "✗ Failed to export attachment - " + errorDetails.joined(separator: ", ")
                log(detailedMessage)
                Logger.noteExport.warning("Failed to export attachment: \(errorDetails.joined(separator: ", "))")
                // Continue with other attachments even if one fails
            }
        }

        // Set attachments folder timestamps to match note's dates
        if !fileAttachments.isEmpty {
            try setFileTimestamps(attachmentsURL, creationDate: noteCreationDate, modificationDate: noteModificationDate)
        }

        return attachmentPaths
    }

    /// Export attachments for a note (thread-safe version for concurrent export)
    private func exportAttachmentsSafely(
        _ attachments: [NotesAttachment],
        toDirectory directory: URL,
        noteBaseName: String,
        noteTitle: String,
        noteCreationDate: Date,
        noteModificationDate: Date,
        tracker: ExportProgressTracker
    ) async throws {
        // Filter out non-file attachments (inline content embedded in note)
        // Note: com.apple.paper, com.apple.drawing, and com.apple.drawing.2 are NOT filtered
        // because they are drawing/sketch attachments with fallback images that should be exported
        let nonFileAttachmentPrefixes = [
            "com.apple.notes.table",                    // Tables
            "com.apple.notes.inlinetextattachment",     // Hashtags, calculations, etc.
            "com.apple.notes.inlinehashtagattachment",  // Hashtags (legacy)
            "com.apple.notes.inlinementionattachment",  // Mentions
            "public.url"                                // URLs
        ]

        let fileAttachments = attachments.filter { attachment in
            !nonFileAttachmentPrefixes.contains { prefix in
                attachment.typeUTI.hasPrefix(prefix)
            }
        }

        // Skip if no file attachments to export
        guard !fileAttachments.isEmpty else {
            return
        }

        // Create attachments subfolder using the unique note base name
        let attachmentsURL = directory.appendingPathComponent("\(noteBaseName) (Attachments)")
        try FileManager.default.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)

        // Track used filenames to handle collisions
        var usedFilenames: [String: Int] = [:]

        // Export each attachment
        for attachment in fileAttachments {
            // Check for cancellation before processing each attachment
            try Task.checkCancellation()

            do {
                // Fetch attachment data from repository
                let data = try await repository.fetchAttachment(id: attachment.id)

                // Determine base filename
                // If attachment.filename is not available, try to get it from the database
                let baseFilename: String
                if let filename = attachment.filename {
                    baseFilename = filename
                } else if let fetchedFilename = await repository.fetchAttachmentFilename(id: attachment.id) {
                    baseFilename = fetchedFilename
                } else {
                    // Final fallback to UUID with extension
                    baseFilename = "\(attachment.id).\(attachment.fileExtension ?? "bin")"
                }

                // Handle filename collisions by adding a counter suffix
                let finalFilename: String
                if let count = usedFilenames[baseFilename] {
                    // This filename has been used before, add a counter
                    let (name, ext) = splitFilename(baseFilename)
                    finalFilename = "\(name) (\(count + 1)).\(ext)"
                    usedFilenames[baseFilename] = count + 1
                } else {
                    // First time using this filename
                    finalFilename = baseFilename
                    usedFilenames[baseFilename] = 1
                }

                let fileURL = attachmentsURL.appendingPathComponent(finalFilename)

                // Write attachment to disk
                try data.write(to: fileURL)

                // Set attachment timestamps to match note's dates
                try setFileTimestamps(fileURL, creationDate: noteCreationDate, modificationDate: noteModificationDate)

                log("✓ Exported attachment: \(finalFilename) for note '\(noteTitle)'")

            } catch {
                await tracker.attachmentFailed()

                // Build detailed error message for user logs
                var errorDetails = [
                    "Attachment ID: \(attachment.id)",
                    "Type: \(attachment.typeUTI)",
                    "Note: '\(noteTitle)'"
                ]

                if let filename = attachment.filename {
                    errorDetails.append("Filename: \(filename)")
                }

                // Include detailed error information
                errorDetails.append("Error: \(error.localizedDescription)")

                if let nsError = error as NSError? {
                    errorDetails.append("Domain: \(nsError.domain)")
                    errorDetails.append("Code: \(nsError.code)")

                    if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                        errorDetails.append("Underlying: \(underlyingError.localizedDescription)")
                    }
                }

                let detailedMessage = "✗ Failed to export attachment - " + errorDetails.joined(separator: ", ")
                log(detailedMessage)
                Logger.noteExport.warning("Failed to export attachment: \(errorDetails.joined(separator: ", "))")
                // Continue with other attachments even if one fails
            }
        }

        // Set attachments folder timestamps to match note's dates
        if !fileAttachments.isEmpty {
            try setFileTimestamps(attachmentsURL, creationDate: noteCreationDate, modificationDate: noteModificationDate)
        }
    }

    /// Cancel the current export operation
    func cancelExport() {
        shouldCancel = true
    }

    /// Reset export state
    func reset() {
        exportState = .idle
        shouldCancel = false
    }

    /// Add a log entry (thread-safe)
    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logLock.lock()
        defer { logLock.unlock() }
        exportLog.append("[\(timestamp)] \(message)")
    }

    private func logPasswordProtectedNoteReport(_ report: PasswordProtectedNoteReport) {
        guard report.hasNotes else { return }

        log("INFO: \(report.summary)")
        for title in report.titles {
            log("  Locked note: \(title)")
        }
    }

    // MARK: - Content Generation

    /// Generate content for a note in the specified format
    private func generateContent(
        for note: NotesNote,
        format: ExportFormat,
        attachmentPaths: [String: String] = [:],
        exportDirectory: URL? = nil,
        rootURL: URL,
        exportPlan: [String: ExportPlanEntry] = [:]
    ) async throws -> String {
        switch format {
        case .html:
            return try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
        case .txt:
            // Generate HTML first, then convert to plain text (includes tables, links, hashtags)
            let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
            let noteWithHTML = NotesNote(
                id: note.id,
                identifier: note.identifier,
                sourceFingerprint: note.sourceFingerprint,
                title: note.title,
                plaintext: note.plaintext,
                htmlBody: html,
                creationDate: note.creationDate,
                modificationDate: note.modificationDate,
                folderId: note.folderId,
                accountId: note.accountId,
                attachments: note.attachments,
                isPasswordProtected: note.isPasswordProtected
            )
            return noteWithHTML.toPlainText()
        case .markdown:
            // Generate HTML first, then convert it to markdown.
            var markdownHTMLConfiguration = configurations.html
            markdownHTMLConfiguration.embedImagesInline = false
            markdownHTMLConfiguration.linkEmbeddedImages = false
            let html = try await generateHTML(
                for: note,
                config: markdownHTMLConfiguration,
                attachmentPaths: attachmentPaths,
                exportDirectory: exportDirectory
            )
            let noteWithHTML = NotesNote(
                id: note.id,
                identifier: note.identifier,
                sourceFingerprint: note.sourceFingerprint,
                title: note.title,
                plaintext: note.plaintext,
                htmlBody: html,
                creationDate: note.creationDate,
                modificationDate: note.modificationDate,
                folderId: note.folderId,
                accountId: note.accountId,
                attachments: note.attachments,
                isPasswordProtected: note.isPasswordProtected
            )
            let linkTargets = noteLinkTargets(for: note, rootURL: rootURL, exportPlan: exportPlan)
            let useObsidianLinks = configurations.obsidianInternalLinksInMarkdown
            let flavor: MarkdownFlavor = useObsidianLinks ? .obsidian : .standard
            let markdown = noteWithHTML.toMarkdown(flavor: flavor, noteLinkTargets: linkTargets)
            let repairedMarkdown = MarkdownAttachmentRepair.repairBareObsidianImageEmbeds(
                in: markdown,
                attachments: note.attachments,
                attachmentPaths: attachmentPaths
            )
            return markdownContent(
                for: repairedMarkdown,
                note: note
            )
        case .rtf:
            // Generate HTML first, then convert to RTF
            let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
            let noteWithHTML = NotesNote(
                id: note.id,
                identifier: note.identifier,
                sourceFingerprint: note.sourceFingerprint,
                title: note.title,
                plaintext: note.plaintext,
                htmlBody: html,
                creationDate: note.creationDate,
                modificationDate: note.modificationDate,
                folderId: note.folderId,
                accountId: note.accountId,
                attachments: note.attachments,
                isPasswordProtected: note.isPasswordProtected
            )
            return noteWithHTML.toRTF(
                fontFamily: configurations.rtf.fontFamily.rtfFontName,
                fontSize: configurations.rtf.fontSizePoints
            )
        case .tex:
            // Generate HTML first, then convert to LaTeX
            let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
            let noteWithHTML = NotesNote(
                id: note.id,
                identifier: note.identifier,
                sourceFingerprint: note.sourceFingerprint,
                title: note.title,
                plaintext: note.plaintext,
                htmlBody: html,
                creationDate: note.creationDate,
                modificationDate: note.modificationDate,
                folderId: note.folderId,
                accountId: note.accountId,
                attachments: note.attachments,
                isPasswordProtected: note.isPasswordProtected
            )
            return noteWithHTML.toLatex(template: configurations.latex.template)
        case .pdf:
            return try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
        }
    }

    // MARK: - Content Generation

    private func generateHTML(
        for note: NotesNote,
        config: HTMLConfiguration? = nil,
        forPDF: Bool = false,
        attachmentPaths: [String: String] = [:],
        exportDirectory: URL? = nil,
        pdfPageSize: CGSize? = nil,
        pdfMargins: NSEdgeInsets? = nil
    ) async throws -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        // Use provided config or default from configurations
        let htmlConfig = config ?? configurations.html

        // Generate HTML on-demand during export if not already present
        let htmlBody: String
        if note.isPasswordProtected {
            htmlBody = """
            <html>
            <body>
                <h1>\(note.title.htmlEscaped)</h1>
                <p>This note is locked in Apple Notes. The title and metadata were exported, but the body is unavailable until the note is unlocked.</p>
            </body>
            </html>
            """
        } else if let existingHTML = note.htmlBody {
            htmlBody = existingHTML
        } else {
            // Generate HTML from protobuf during export
            do {
                htmlBody = try await repository.generateHTML(forNoteId: note.id)
            } catch {
                // Fallback to plaintext if HTML generation fails (corrupted protobuf, etc.)
                Logger.noteExport.warning("Failed to generate HTML for note \(note.id), falling back to plaintext: \(error)")
                // Create a properly structured HTML document for PDF rendering
                htmlBody = """
                <html>
                <head>
                    <meta charset="UTF-8">
                    <meta name="viewport" content="width=device-width, initial-scale=1.0">
                    <style>
                        body { font-family: -apple-system, system-ui; font-size: 12pt; line-height: 1.6; }
                        pre { white-space: pre-wrap; word-wrap: break-word; }
                    </style>
                </head>
                <body>
                    <pre>\(note.plaintext.htmlEscaped)</pre>
                </body>
                </html>
                """
            }
        }

        // Process HTML to replace attachment markers with actual content
        var processedHTML = htmlBody

        // Only process attachments if we have a database connection and attachments to process
        if !note.attachments.isEmpty {
            // Open a C parser handle and extract the sqlite3 pointer for HTMLAttachmentProcessor
            if let parserHandle = ane_open(databasePath) {
                defer { ane_close(parserHandle) }
                if let rawHandle = ane_get_sqlite_handle(parserHandle) {
                    let database = OpaquePointer(rawHandle)
                    let processor = HTMLAttachmentProcessor(database: database)
                    processedHTML = processor.processHTML(
                        html: htmlBody,
                        attachments: note.attachments,
                        attachmentPaths: attachmentPaths,
                        exportDirectory: exportDirectory?.path,
                        embedImages: htmlConfig.embedImagesInline,
                        linkEmbeddedImages: htmlConfig.linkEmbeddedImages
                    )
                }
            }
        }

        // Build CSS for font and margin
        let fontFamily = htmlConfig.fontFamily.cssFontStack
        let fontSize = "\(htmlConfig.fontSizePoints)pt"

        // For PDF, margins are handled by PDFConfiguration (set body margin to 0)
        // For HTML export, use the configured margin value
        let marginValue = forPDF ? "0" : "\(htmlConfig.marginSize)\(htmlConfig.marginUnit.displayName)"

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <meta name="created" content="\(dateFormatter.string(from: note.creationDate))">
            <meta name="modified" content="\(dateFormatter.string(from: note.modificationDate))">
            <title>\(note.title.htmlEscaped)</title>
            <style>
                body {
                    font-family: \(fontFamily);
                    font-size: \(fontSize);
                    max-width: 800px;
                    margin: \(marginValue) auto;
                    padding: 0 20px;
                    line-height: 1.0;
                }
                /* Remove all spacing around headings and paragraphs */
                h1, h2, h3, h4, h5, h6, p {
                    margin: 0;
                    padding: 0;
                    line-height: 1.0;
                }
                /* Remove spacing around lists but keep indentation */
                ul, ol {
                    margin: 0;
                    margin-left: 1.5em;
                    padding: 0;
                    padding-left: 0.5em;
                }
                li {
                    margin: 0;
                    padding: 0;
                    line-height: 1.0;
                }
                img {
                    max-width: 100%;
                    \(generateImageHeightConstraint(forPDF: forPDF, pageSize: pdfPageSize, margins: pdfMargins))
                }
            </style>
        </head>
        <body>
            <div class="content">
                \(processedHTML)
            </div>
        </body>
        </html>
        """
    }

    // MARK: - Helper Methods

    /// Generate CSS constraint for image height in PDFs
    private func generateImageHeightConstraint(forPDF: Bool, pageSize: CGSize?, margins: NSEdgeInsets?) -> String {
        guard forPDF, let pageSize = pageSize, let margins = margins else {
            return "" // No constraint for non-PDF exports
        }

        // Calculate maximum image height: page height - top margin - bottom margin
        // Use points as CSS unit (1 point = 1/72 inch, standard for PDF)
        let maxHeight = pageSize.height - margins.top - margins.bottom

        // Add some padding to ensure images don't touch margins (subtract 20pt)
        let safeMaxHeight = max(100, maxHeight - 20)

        return "max-height: \(safeMaxHeight)pt; height: auto;"
    }

    private func notesExcludingRecentlyDeleted(_ notes: [NotesNote]) async throws -> [NotesNote] {
        let folders = try await repository.fetchFolders()
        let folderLookup = Swift.Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        return notes.filter { note in
            !isInRecentlyDeleted(folderId: note.folderId, folderLookup: folderLookup)
        }
    }

    private func isInRecentlyDeleted(folderId: String, folderLookup: [String: NotesFolder]) -> Bool {
        var currentFolderId: String? = folderId
        var visitedFolderIDs: Set<String> = []

        while let id = currentFolderId,
              let folder = folderLookup[id],
              !visitedFolderIDs.contains(id) {
            visitedFolderIDs.insert(id)

            if isRecentlyDeletedFolderName(folder.name) {
                return true
            }

            currentFolderId = folder.parentId
        }

        return false
    }

    private func isRecentlyDeletedFolderName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare("Recently Deleted") == .orderedSame
    }

    /// Organize notes by account and folder hierarchy
    private func organizeNotesByHierarchy(_ notes: [NotesNote]) async throws -> [String: [String: [NotesNote]]] {
        var hierarchy: [String: [String: [NotesNote]]] = [:]

        // Fetch all accounts and folders from repository
        let accounts = try await repository.fetchAccounts()
        let folders = try await repository.fetchFolders()

        // Create lookup dictionaries for faster access
        var accountLookup: [String: String] = [:]
        for account in accounts {
            accountLookup[account.id] = account.name
        }

        var folderLookup: [String: NotesFolder] = [:]
        for folder in folders {
            folderLookup[folder.id] = folder
        }

        for note in notes {
            let accountName = accountLookup[note.accountId] ?? "Unknown Account"
            let accountKey = sanitizeFilename(accountName)

            // Build folder path by walking up the parent chain
            let folderPath = buildFolderPath(folderId: note.folderId, folderLookup: folderLookup)

            if hierarchy[accountKey] == nil {
                hierarchy[accountKey] = [:]
            }

            if hierarchy[accountKey]![folderPath] == nil {
                hierarchy[accountKey]![folderPath] = []
            }

            hierarchy[accountKey]![folderPath]!.append(note)
        }

        return hierarchy
    }

    private func flattenNotesWithPaths(
        from hierarchy: [String: [String: [NotesNote]]],
        outputURL: URL
    ) -> [(note: NotesNote, folderURL: URL)] {
        var notesWithPaths: [(note: NotesNote, folderURL: URL)] = []
        for (accountName, folders) in hierarchy {
            let accountURL = outputURL.appendingPathComponent(sanitizeFilename(accountName))
            for (folderPath, folderNotes) in folders {
                let folderURL = accountURL.appendingPathComponent(folderPath)
                for note in folderNotes {
                    notesWithPaths.append((note: note, folderURL: folderURL))
                }
            }
        }
        return notesWithPaths
    }

    /// Build a folder path string by walking up the parent folder chain
    private func buildFolderPath(folderId: String, folderLookup: [String: NotesFolder]) -> String {
        guard let folder = folderLookup[folderId] else {
            return sanitizeFilename("Unknown Folder")
        }

        var pathComponents: [String] = [sanitizeFilename(folder.name)]

        // Walk up the parent chain
        var currentParentId = folder.parentId
        while let parentId = currentParentId, let parentFolder = folderLookup[parentId] {
            pathComponents.insert(sanitizeFilename(parentFolder.name), at: 0)
            currentParentId = parentFolder.parentId
        }

        // Join with "/" to create a relative path
        return pathComponents.joined(separator: "/")
    }

    /// Split a filename into name and extension
    private func splitFilename(_ filename: String) -> (name: String, ext: String) {
        if let lastDotIndex = filename.lastIndex(of: "."),
           lastDotIndex != filename.startIndex {
            let name = String(filename[..<lastDotIndex])
            let ext = String(filename[filename.index(after: lastDotIndex)...])
            return (name, ext)
        } else {
            // No extension found
            return (filename, "")
        }
    }

    /// Set file creation and modification timestamps
    private func setFileTimestamps(_ fileURL: URL, creationDate: Date, modificationDate: Date) throws {
        let attributes: [FileAttributeKey: Any] = [
            .creationDate: creationDate,
            .modificationDate: modificationDate
        ]
        try FileManager.default.setAttributes(attributes, ofItemAtPath: fileURL.path)
    }

    /// Set folder timestamps based on the oldest creation date and latest modification date of notes within
    private func setFolderTimestamps(hierarchy: [String: [String: [NotesNote]]], outputURL: URL) async throws {
        for (accountName, folders) in hierarchy {
            let accountURL = outputURL.appendingPathComponent(sanitizeFilename(accountName))

            // Track dates for the account
            var accountOldestCreation: Date?
            var accountLatestModification: Date?

            for (folderPath, notes) in folders {
                guard !notes.isEmpty else { continue }

                let folderURL = accountURL.appendingPathComponent(folderPath)

                // Find oldest creation and latest modification among all notes in this folder
                let oldestCreation = notes.map { $0.creationDate }.min() ?? Date()
                let latestModification = notes.map { $0.modificationDate }.max() ?? Date()

                // Set folder timestamps
                try setFileTimestamps(folderURL, creationDate: oldestCreation, modificationDate: latestModification)

                // Track for account-level timestamps
                if accountOldestCreation == nil || oldestCreation < accountOldestCreation! {
                    accountOldestCreation = oldestCreation
                }
                if accountLatestModification == nil || latestModification > accountLatestModification! {
                    accountLatestModification = latestModification
                }
            }

            // Set account folder timestamps
            if let oldestCreation = accountOldestCreation,
               let latestModification = accountLatestModification {
                try setFileTimestamps(accountURL, creationDate: oldestCreation, modificationDate: latestModification)
            }
        }
    }

    /// Sanitize filename for filesystem
    private func sanitizeFilename(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
            .union(.newlines)
            .union(.illegalCharacters)
            .union(.controlCharacters)

        return name.components(separatedBy: invalidCharacters).joined(separator: "_")
    }

    private func preferredBaseFilename(for note: NotesNote) -> String {
        let titleComponent = note.sanitizedFileName

        if configurations.addDateToFilename {
            let formatter = DateFormatter()
            formatter.dateFormat = configurations.filenameDateFormat.rawValue
            let datePrefix = formatter.string(from: note.creationDate)
            let remainingLength = max(16, NotesNote.maximumSanitizedFilenameLength - datePrefix.count - 1)
            let truncatedTitle = NotesNote.truncatedFilenameComponent(
                titleComponent,
                maximumLength: remainingLength
            )
            return "\(datePrefix) \(truncatedTitle)"
        }

        return titleComponent
    }

    /// Format time remaining for display
    private func formatTimeRemaining(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s"
        } else if seconds < 3600 {
            let minutes = Int(seconds / 60)
            return "\(minutes)m"
        } else {
            let hours = Int(seconds / 3600)
            let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(hours)h \(minutes)m"
        }
    }

    /// Generate unique filename by checking for collisions and appending counter if needed
    private func generateUniqueFilename(baseName: String, extension: String, inDirectory directory: URL) -> String {
        let initialFilename = "\(baseName).\(`extension`)"
        let initialURL = directory.appendingPathComponent(initialFilename)

        // If no collision, use the original name
        if !FileManager.default.fileExists(atPath: initialURL.path) {
            return initialFilename
        }

        // File exists, find unique name by appending counter (starting from 2)
        var counter = 2
        while true {
            let uniqueFilename = "\(baseName) (\(counter)).\(`extension`)"
            let uniqueURL = directory.appendingPathComponent(uniqueFilename)

            if !FileManager.default.fileExists(atPath: uniqueURL.path) {
                return uniqueFilename
            }

            counter += 1

            // Safety limit to prevent infinite loop
            if counter > 10000 {
                // Fall back to using UUID if we somehow have 10000 files with same name
                return "\(baseName)_\(UUID().uuidString).\(`extension`)"
            }
        }
    }

    private func generateUniqueFilename(
        baseName: String,
        extension: String,
        inDirectory directory: URL,
        reservedPaths: inout Set<String>
    ) -> String {
        let initialFilename = "\(baseName).\(`extension`)"
        let initialPath = directory.appendingPathComponent(initialFilename).path
        if !FileManager.default.fileExists(atPath: initialPath) && !reservedPaths.contains(initialPath) {
            reservedPaths.insert(initialPath)
            return initialFilename
        }

        var counter = 2
        while true {
            let uniqueFilename = "\(baseName) (\(counter)).\(`extension`)"
            let uniquePath = directory.appendingPathComponent(uniqueFilename).path

            if !FileManager.default.fileExists(atPath: uniquePath) && !reservedPaths.contains(uniquePath) {
                reservedPaths.insert(uniquePath)
                return uniqueFilename
            }

            counter += 1
            if counter > 10000 {
                let fallback = "\(baseName)_\(UUID().uuidString).\(`extension`)"
                reservedPaths.insert(directory.appendingPathComponent(fallback).path)
                return fallback
            }
        }
    }

    private func buildExportPlan(
        for notesWithPaths: [(note: NotesNote, folderURL: URL)],
        format: ExportFormat,
        rootURL: URL,
        syncManifest: SyncManifest?,
        isSync: Bool
    ) -> [String: ExportPlanEntry] {
        var exportPlan: [String: ExportPlanEntry] = [:]
        var reservedPaths: Set<String> = []

        for noteWithPath in notesWithPaths {
            let note = noteWithPath.note
            let directory = noteWithPath.folderURL
            let planEntry: ExportPlanEntry

            if let overridePath = syncManifest?.existingPath(for: note.id),
               shouldReuseManifestPath(
                overridePath,
                for: note,
                currentDirectory: directory,
                rootURL: rootURL
               ) {
                let fileURL = rootURL.appendingPathComponent(overridePath)
                reservedPaths.insert(fileURL.path)
                planEntry = ExportPlanEntry(
                    folderURL: directory,
                    fileURL: fileURL,
                    uniqueBaseName: fileURL.deletingPathExtension().lastPathComponent,
                    noteIdentifier: note.identifier,
                    noteTitle: note.title
                )
            } else {
                let baseFilename = preferredBaseFilename(for: note)

                if isSync,
                   let existingSyncFileURL = findExistingSyncFileURL(
                    for: note,
                    baseName: baseFilename,
                    format: format,
                    inDirectory: directory
                   ) {
                    reservedPaths.insert(existingSyncFileURL.path)
                    planEntry = ExportPlanEntry(
                        folderURL: directory,
                        fileURL: existingSyncFileURL,
                        uniqueBaseName: existingSyncFileURL.deletingPathExtension().lastPathComponent,
                        noteIdentifier: note.identifier,
                        noteTitle: note.title
                    )
                } else {
                    let filename = generateUniqueFilename(
                        baseName: baseFilename,
                        extension: format.fileExtension,
                        inDirectory: directory,
                        reservedPaths: &reservedPaths
                    )
                    let fileURL = directory.appendingPathComponent(filename)
                    planEntry = ExportPlanEntry(
                        folderURL: directory,
                        fileURL: fileURL,
                        uniqueBaseName: fileURL.deletingPathExtension().lastPathComponent,
                        noteIdentifier: note.identifier,
                        noteTitle: note.title
                    )
                }
            }

            exportPlan[note.id] = planEntry
        }

        return exportPlan
    }

    private func noteLinkTargets(
        for sourceNote: NotesNote,
        rootURL: URL,
        exportPlan: [String: ExportPlanEntry]
    ) -> [String: NoteLinkTarget] {
        guard let sourceEntry = exportPlan[sourceNote.id] else {
            return [:]
        }

        var targets: [String: NoteLinkTarget] = [:]

        for (noteID, targetEntry) in exportPlan where noteID != sourceNote.id {
            let markdownPath = relativePath(from: sourceEntry.folderURL, to: targetEntry.fileURL)
            let vaultRelativePath = relativePath(from: rootURL, to: targetEntry.fileURL)
            let suffix = ".\(ExportFormat.markdown.fileExtension)"
            let obsidianReference = vaultRelativePath.hasSuffix(suffix)
                ? String(vaultRelativePath.dropLast(suffix.count))
                : vaultRelativePath

            let linkTarget = NoteLinkTarget(
                markdownPath: markdownPath,
                obsidianReference: obsidianReference,
                title: targetEntry.noteTitle
            )

            for token in noteLinkTokens(noteID: noteID, identifier: targetEntry.noteIdentifier) {
                targets[token] = linkTarget
            }
        }

        return targets
    }

    private func noteLinkTokens(noteID: String, identifier: String?) -> Set<String> {
        var tokens: Set<String> = []

        func addTokenVariants(_ token: String) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return
            }

            tokens.insert(trimmed)
            tokens.insert(trimmed.lowercased())
            tokens.insert(trimmed.uppercased())

            let normalized = trimmed
                .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                .replacingOccurrences(of: "x-coredata://", with: "", options: .caseInsensitive)
            if normalized != trimmed, !normalized.isEmpty {
                tokens.insert(normalized)
                tokens.insert(normalized.lowercased())
                tokens.insert(normalized.uppercased())
            }
        }

        addTokenVariants(noteID)
        if let identifier {
            addTokenVariants(identifier)
        }

        return tokens
    }

    private func relativePath(from baseDirectory: URL, to targetURL: URL) -> String {
        let baseComponents = baseDirectory.standardizedFileURL.pathComponents
        let targetComponents = targetURL.standardizedFileURL.pathComponents

        var commonIndex = 0
        while commonIndex < min(baseComponents.count, targetComponents.count),
              baseComponents[commonIndex] == targetComponents[commonIndex] {
            commonIndex += 1
        }

        let upwardPath = Array(repeating: "..", count: max(0, baseComponents.count - commonIndex))
        let downwardPath = Array(targetComponents.dropFirst(commonIndex))
        return (upwardPath + downwardPath).joined(separator: "/")
    }

    private func shouldReuseManifestPath(
        _ existingRelativePath: String,
        for note: NotesNote,
        currentDirectory: URL,
        rootURL: URL
    ) -> Bool {
        let existingURL = rootURL.appendingPathComponent(existingRelativePath)
        let existingDirectory = existingURL.deletingLastPathComponent().standardizedFileURL
        let currentDirectory = currentDirectory.standardizedFileURL

        guard existingDirectory.path == currentDirectory.path else {
            return false
        }

        let existingBaseName = existingURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredBaseName = preferredBaseFilename(for: note)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !existingBaseName.isEmpty else {
            return false
        }

        return isDerivedFilename(existingBaseName, fromPreferredBase: preferredBaseName)
    }

    private func normalizedAttachmentFilename(_ rawFilename: String, for attachment: NotesAttachment) -> String {
        let trimmed = rawFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastPathComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        let fallbackName = lastPathComponent.isEmpty ? attachment.id : lastPathComponent
        let sanitized = sanitizeFilename(fallbackName)
        let baseName = sanitized.isEmpty ? attachment.id : sanitized

        if URL(fileURLWithPath: baseName).pathExtension.isEmpty,
           let fileExtension = attachment.fileExtension,
           !fileExtension.isEmpty {
            return "\(baseName).\(fileExtension)"
        }

        return baseName
    }

    private func currentExportFingerprint(for format: ExportFormat) -> String {
        switch format {
        case .markdown:
            return "format=MD;obsidianLinks=\(configurations.obsidianInternalLinksInMarkdown);attachmentMode=fileLinks-v3;filenameSanitizer=visualSlash-v1"
        default:
            return "format=\(format.rawValue)"
        }
    }

    private func noteContentFingerprint(_ note: NotesNote) -> String {
        NoteContentFingerprint.value(for: note)
    }

    private func markdownContent(for content: String, note: NotesNote) -> String {
        return stripLegacyMarkdownMetadata(from: content)
    }

    private func findExistingSyncFileURL(
        for note: NotesNote,
        baseName: String,
        format: ExportFormat,
        inDirectory directory: URL
    ) -> URL? {
        let preferredURL = directory.appendingPathComponent("\(baseName).\(format.fileExtension)")
        if FileManager.default.fileExists(atPath: preferredURL.path) {
            return preferredURL
        }

        guard format.fileExtension == ExportFormat.markdown.fileExtension else {
            return nil
        }

        if let matchedByMetadata = findMarkdownFile(matching: note, inDirectory: directory) {
            return matchedByMetadata
        }

        let numberedCandidates = findNumberedFilenameCandidates(
            baseName: baseName,
            fileExtension: format.fileExtension,
            inDirectory: directory
        )
        if numberedCandidates.count == 1 {
            return numberedCandidates[0]
        }

        return nil
    }

    private func isDerivedFilename(_ existingBaseName: String, fromPreferredBase preferredBaseName: String) -> Bool {
        let normalizedExisting = existingBaseName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPreferred = preferredBaseName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !normalizedExisting.isEmpty, !normalizedPreferred.isEmpty else {
            return false
        }

        if normalizedExisting == normalizedPreferred {
            return true
        }

        let numberedPattern = #"^(.+?) \((\d+)\)$"#
        guard let regex = try? NSRegularExpression(pattern: numberedPattern) else {
            return false
        }

        let range = NSRange(location: 0, length: existingBaseName.utf16.count)
        guard let match = regex.firstMatch(in: existingBaseName, options: [], range: range),
              match.numberOfRanges == 3,
              let baseRange = Range(match.range(at: 1), in: existingBaseName) else {
            return false
        }

        return existingBaseName[baseRange].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedPreferred
    }

    private func staleExportArtifacts(
        previousEntry: SyncManifest.SyncedNoteEntry?,
        plannedFileURL: URL,
        noteDirectory: URL,
        rootURL: URL?
    ) -> StaleExportArtifacts? {
        guard let previousEntry, let rootURL else {
            return nil
        }

        let previousFileURL = rootURL.appendingPathComponent(previousEntry.exportedPath)
        let previousAttachmentURLs = previousEntry.attachmentPaths.map { rootURL.appendingPathComponent($0) }
        let hasMovedFile = previousFileURL.standardizedFileURL.path != plannedFileURL.standardizedFileURL.path
        let hasMovedAttachments = previousAttachmentURLs.contains { attachmentURL in
            attachmentURL.deletingLastPathComponent().standardizedFileURL.path != noteDirectory.standardizedFileURL.path
        }

        guard hasMovedFile || hasMovedAttachments else {
            return nil
        }

        return StaleExportArtifacts(fileURL: previousFileURL, attachmentURLs: previousAttachmentURLs)
    }

    private func removeStaleExportArtifacts(
        _ staleArtifacts: StaleExportArtifacts?,
        preservingFilePaths: some Sequence<URL>,
        preservingAttachmentRelativePaths: some Sequence<String>,
        rootURL: URL?
    ) throws {
        guard let staleArtifacts else {
            return
        }

        let fileManager = FileManager.default
        let preservedFilePaths = Set(preservingFilePaths.map { $0.standardizedFileURL.path })
        if let rootURL,
           isURLInsideDirectory(staleArtifacts.fileURL, directoryURL: rootURL),
           !preservedFilePaths.contains(staleArtifacts.fileURL.standardizedFileURL.path),
           fileManager.fileExists(atPath: staleArtifacts.fileURL.path) {
            try? fileManager.removeItem(at: staleArtifacts.fileURL)
        }

        let preservedAttachmentPaths = Set(
            preservingAttachmentRelativePaths.compactMap { relativePath in
                rootURL?.appendingPathComponent(relativePath).standardizedFileURL.path
            }
        )

        for attachmentURL in staleArtifacts.attachmentURLs {
            let standardizedPath = attachmentURL.standardizedFileURL.path
            guard let rootURL,
                  isURLInsideDirectory(attachmentURL, directoryURL: rootURL),
                  !preservedAttachmentPaths.contains(standardizedPath) else {
                continue
            }
            if fileManager.fileExists(atPath: standardizedPath) {
                try? fileManager.removeItem(at: attachmentURL)
            }
            try removeDirectoryIfEmpty(attachmentURL.deletingLastPathComponent(), stoppingAt: rootURL)
        }
    }

    private func removeManifestEntriesNotInCurrentExportSet(
        from manifest: inout SyncManifest,
        currentNoteIDs: Set<String>,
        outputRootURL: URL
    ) throws -> Int {
        let protectedPaths = Set(
            manifest.notes
                .filter { currentNoteIDs.contains($0.key) }
                .flatMap { _, entry in
                    [entry.exportedPath] + entry.attachmentPaths
                }
                .compactMap { outputURL(forManifestPath: $0, inside: outputRootURL)?.standardizedFileURL.path }
        )

        let staleNoteIDs = manifest.notes.keys.filter { !currentNoteIDs.contains($0) }
        guard !staleNoteIDs.isEmpty else {
            return 0
        }

        let fileManager = FileManager.default
        for noteID in staleNoteIDs {
            guard let entry = manifest.notes[noteID] else { continue }

            guard let fileURL = outputURL(forManifestPath: entry.exportedPath, inside: outputRootURL) else {
                manifest.notes.removeValue(forKey: noteID)
                continue
            }
            let filePath = fileURL.standardizedFileURL.path
            if !protectedPaths.contains(filePath),
               fileManager.fileExists(atPath: filePath) {
                try? fileManager.removeItem(at: fileURL)
                try removeDirectoryIfEmpty(fileURL.deletingLastPathComponent(), stoppingAt: outputRootURL)
            }

            for attachmentPath in entry.attachmentPaths {
                guard let attachmentURL = outputURL(forManifestPath: attachmentPath, inside: outputRootURL) else {
                    continue
                }
                let standardizedAttachmentPath = attachmentURL.standardizedFileURL.path
                guard !protectedPaths.contains(standardizedAttachmentPath) else {
                    continue
                }

                if fileManager.fileExists(atPath: standardizedAttachmentPath) {
                    try? fileManager.removeItem(at: attachmentURL)
                }
                try removeDirectoryIfEmpty(attachmentURL.deletingLastPathComponent(), stoppingAt: outputRootURL)
            }

            manifest.notes.removeValue(forKey: noteID)
        }

        return staleNoteIDs.count
    }

    private func removeUntrackedExportArtifacts(
        preserving manifest: SyncManifest,
        outputRootURL: URL
    ) throws -> (files: Int, directories: Int) {
        let fileManager = FileManager.default
        let outputRootURL = outputRootURL.standardizedFileURL
        var protectedFilePaths: Set<String> = [
            outputRootURL.appendingPathComponent(SyncManifest.filename).standardizedFileURL.path
        ]
        var protectedAttachmentDirectoryPaths: Set<String> = []

        for entry in manifest.notes.values {
            if let exportedURL = outputURL(forManifestPath: entry.exportedPath, inside: outputRootURL) {
                protectedFilePaths.insert(exportedURL.standardizedFileURL.path)
            }

            for attachmentPath in entry.attachmentPaths {
                guard let attachmentURL = outputURL(forManifestPath: attachmentPath, inside: outputRootURL) else {
                    continue
                }
                protectedFilePaths.insert(attachmentURL.standardizedFileURL.path)
                protectedAttachmentDirectoryPaths.insert(attachmentURL.deletingLastPathComponent().standardizedFileURL.path)
            }
        }

        guard let enumerator = fileManager.enumerator(
            at: outputRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return (files: 0, directories: 0)
        }

        var untrackedMarkdownFiles: [URL] = []
        var candidateAttachmentDirectories: [URL] = []

        for case let url as URL in enumerator {
            let standardizedURL = url.standardizedFileURL
            guard isURLInsideDirectory(standardizedURL, directoryURL: outputRootURL) else {
                continue
            }

            let resourceValues = try? standardizedURL.resourceValues(forKeys: [.isDirectoryKey])
            if resourceValues?.isDirectory == true {
                if isExporterAttachmentDirectoryName(standardizedURL.lastPathComponent),
                   !protectedAttachmentDirectoryPaths.contains(standardizedURL.path) {
                    candidateAttachmentDirectories.append(standardizedURL)
                    enumerator.skipDescendants()
                }
                continue
            }

            if standardizedURL.pathExtension.localizedCaseInsensitiveCompare(ExportFormat.markdown.fileExtension) == .orderedSame,
               !protectedFilePaths.contains(standardizedURL.path) {
                untrackedMarkdownFiles.append(standardizedURL)
            }
        }

        var removedFiles = 0
        for fileURL in untrackedMarkdownFiles {
            guard isURLInsideDirectory(fileURL, directoryURL: outputRootURL),
                  fileManager.fileExists(atPath: fileURL.path) else {
                continue
            }

            try? fileManager.removeItem(at: fileURL)
            removedFiles += 1
            try removeDirectoryIfEmpty(fileURL.deletingLastPathComponent(), stoppingAt: outputRootURL)
        }

        let protectedMarkdownPaths = protectedFilePaths.filter { $0.hasSuffix(".\(ExportFormat.markdown.fileExtension)") }
        var removedDirectories = 0
        let sortedAttachmentDirectories = candidateAttachmentDirectories.sorted { $0.path.count > $1.path.count }
        for directoryURL in sortedAttachmentDirectories {
            guard isURLInsideDirectory(directoryURL, directoryURL: outputRootURL),
                  fileManager.fileExists(atPath: directoryURL.path) else {
                continue
            }

            let siblingMarkdownPath = siblingMarkdownPath(forAttachmentDirectory: directoryURL)
            guard siblingMarkdownPath == nil || !protectedMarkdownPaths.contains(siblingMarkdownPath!) else {
                continue
            }

            try? fileManager.removeItem(at: directoryURL)
            removedDirectories += 1
            try removeDirectoryIfEmpty(directoryURL.deletingLastPathComponent(), stoppingAt: outputRootURL)
        }

        return (files: removedFiles, directories: removedDirectories)
    }

    private func isExporterAttachmentDirectoryName(_ name: String) -> Bool {
        name.hasSuffix(" (Attachments)") || name.hasSuffix(" (Resources)")
    }

    private func siblingMarkdownPath(forAttachmentDirectory directoryURL: URL) -> String? {
        let name = directoryURL.lastPathComponent
        let suffixes = [" (Attachments)", " (Resources)"]
        guard let suffix = suffixes.first(where: { name.hasSuffix($0) }) else {
            return nil
        }

        let baseName = String(name.dropLast(suffix.count))
        guard !baseName.isEmpty else {
            return nil
        }

        return directoryURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(baseName).\(ExportFormat.markdown.fileExtension)")
            .standardizedFileURL
            .path
    }

    private func outputURL(forManifestPath relativePath: String, inside outputRootURL: URL) -> URL? {
        let candidateURL = outputRootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard isURLInsideDirectory(candidateURL, directoryURL: outputRootURL) else {
            return nil
        }
        return candidateURL
    }

    private func isURLInsideDirectory(_ url: URL, directoryURL: URL) -> Bool {
        let baseComponents = directoryURL.standardizedFileURL.pathComponents
        let targetComponents = url.standardizedFileURL.pathComponents

        guard targetComponents.count > baseComponents.count else {
            return false
        }

        return zip(baseComponents, targetComponents).allSatisfy(==)
    }

    private func removeDirectoryIfEmpty(_ directoryURL: URL, stoppingAt rootURL: URL? = nil) throws {
        let fileManager = FileManager.default
        if let rootURL, !isURLInsideDirectory(directoryURL, directoryURL: rootURL) {
            return
        }

        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return
        }

        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard contents.isEmpty else {
            return
        }

        try? fileManager.removeItem(at: directoryURL)
    }

    private func findMarkdownFile(matching note: NotesNote, inDirectory directory: URL) -> URL? {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let matchingFiles = fileURLs.filter { fileURL in
            guard fileURL.pathExtension.lowercased() == ExportFormat.markdown.fileExtension else {
                return false
            }
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return false
            }
            return markdownContainsMetadata(contents, for: note)
        }

        return matchingFiles.count == 1 ? matchingFiles[0] : nil
    }

    private func markdownContainsMetadata(_ contents: String, for note: NotesNote) -> Bool {
        if contents.hasPrefix("<!-- AppleNotesExporter: note-id=\(note.id) -->") {
            return true
        }

        if let identifier = note.identifier,
           contents.contains("<!-- AppleNotesExporter: note-identifier=\(identifier) -->") {
            return true
        }

        return false
    }

    private func notesNeedingMarkdownCleanup(
        from notes: [NotesNote],
        manifest: SyncManifest,
        outputRootURL: URL
    ) -> [NotesNote] {
        notes.filter { note in
            guard let existingPath = manifest.existingPath(for: note.id) else {
                return false
            }
            let fileURL = outputRootURL.appendingPathComponent(existingPath)
            guard fileURL.pathExtension.lowercased() == ExportFormat.markdown.fileExtension,
                  let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return false
            }
            return markdownNeedsLegacyMetadataCleanup(contents)
        }
    }

    private func markdownNeedsLegacyMetadataCleanup(_ contents: String) -> Bool {
        contents.contains("<!-- AppleNotesExporter: note-id=") ||
        contents.contains("<!-- AppleNotesExporter: note-identifier=")
    }

    private func notesMissingExportArtifacts(
        from notes: [NotesNote],
        manifest: SyncManifest,
        outputRootURL: URL
    ) -> [NotesNote] {
        notes.filter { note in
            guard let entry = manifest.notes[note.id] else {
                return false
            }

            let fileURL = outputRootURL.appendingPathComponent(entry.exportedPath)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                return true
            }

            return entry.attachmentPaths.contains { relativePath in
                !FileManager.default.fileExists(atPath: outputRootURL.appendingPathComponent(relativePath).path)
            }
        }
    }

    private func stripLegacyMarkdownMetadata(from content: String) -> String {
        let cleaned = content.replacingOccurrences(
            of: #"(?m)^<!-- AppleNotesExporter: note-(id|identifier)=[^>]+ -->\n?"#,
            with: "",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func findNumberedFilenameCandidates(
        baseName: String,
        fileExtension: String,
        inDirectory directory: URL
    ) -> [URL] {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let prefix = "\(baseName) ("
        let suffix = ").\(fileExtension)"

        return fileURLs.filter { fileURL in
            let lastPathComponent = fileURL.lastPathComponent
            guard lastPathComponent.hasPrefix(prefix),
                  lastPathComponent.hasSuffix(suffix) else {
                return false
            }

            let startIndex = lastPathComponent.index(lastPathComponent.startIndex, offsetBy: prefix.count)
            let endIndex = lastPathComponent.index(lastPathComponent.endIndex, offsetBy: -suffix.count)
            let counterText = String(lastPathComponent[startIndex..<endIndex])
            return Int(counterText) != nil
        }
    }
}

// MARK: - String Extensions for Escaping

extension String {
    var htmlEscaped: String {
        self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    var rtfEscaped: String {
        self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
    }

    var texEscaped: String {
        self
            .replacingOccurrences(of: "\\", with: "\\textbackslash{}")
            .replacingOccurrences(of: "&", with: "\\&")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "#", with: "\\#")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "~", with: "\\textasciitilde{}")
            .replacingOccurrences(of: "^", with: "\\textasciicircum{}")
    }
}

private extension Array where Element == NotesNote {
    func countMatchingExportFingerprintChange(
        manifest: SyncManifest,
        exportFingerprint: String?
    ) -> Int {
        filter { note in
            guard let entry = manifest.notes[note.id] else {
                return false
            }
            let modificationDelta = note.modificationDate.timeIntervalSince1970 - entry.modificationDate.timeIntervalSince1970
            return modificationDelta <= 0.001 && entry.exportFingerprint != exportFingerprint
        }.count
    }
}

enum MarkdownAttachmentRepair {
    static func repairBareObsidianImageEmbeds(
        in markdown: String,
        attachments: [NotesAttachment],
        attachmentPaths: [String: String]
    ) -> String {
        let imagePaths = attachments.compactMap { attachment -> String? in
            guard isImageAttachment(attachment) else { return nil }
            return attachmentPaths[attachment.id]
        }
        guard !imagePaths.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"\!\[\[([^\]]+)\]\]"#) else {
            return markdown
        }

        let nsString = markdown as NSString
        let matches = regex.matches(in: markdown, options: [], range: NSRange(location: 0, length: nsString.length))
        var replacements: [(range: NSRange, value: String)] = []
        var nextImagePathIndex = 0

        for match in matches {
            guard match.numberOfRanges >= 2,
                  nextImagePathIndex < imagePaths.count else {
                continue
            }

            let embedTarget = nsString.substring(with: match.range(at: 1))
            guard shouldRepairObsidianImageTarget(embedTarget) else {
                continue
            }

            let repairedPath = imagePaths[nextImagePathIndex]
            replacements.append((range: match.range(at: 0), value: "![[\(repairedPath)]]"))
            nextImagePathIndex += 1
        }

        guard !replacements.isEmpty else {
            return markdown
        }

        var result = markdown
        for replacement in replacements.reversed() {
            result = (result as NSString).replacingCharacters(in: replacement.range, with: replacement.value)
        }
        return result
    }

    private static func shouldRepairObsidianImageTarget(_ target: String) -> Bool {
        let path = target
            .split(separator: "|", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return true }

        if path.contains("/") || path.contains("\\") {
            return false
        }

        let knownImageExtensions = ["jpg", "jpeg", "png", "gif", "heic", "tif", "tiff", "webp", "bmp"]
        return !knownImageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private static func isImageAttachment(_ attachment: NotesAttachment) -> Bool {
        attachment.typeUTI.hasPrefix("public.image") ||
        attachment.typeUTI.hasPrefix("public.jpeg") ||
        attachment.typeUTI.hasPrefix("public.png") ||
        attachment.typeUTI.hasPrefix("public.heic") ||
        attachment.typeUTI.hasPrefix("public.tiff") ||
        attachment.typeUTI.hasPrefix("com.compuserve.gif") ||
        attachment.typeUTI == "com.compuserve.gif" ||
        attachment.typeUTI == "com.apple.paper" ||
        attachment.typeUTI == "com.apple.drawing" ||
        attachment.typeUTI == "com.apple.drawing.2" ||
        attachment.typeUTI == "com.apple.notes.gallery"
    }
}
