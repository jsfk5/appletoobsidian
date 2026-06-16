//
//  AppleNotesExporterApp.swift
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

import SwiftUI
import OSLog
import Darwin

// ** Declare Constants
// App version and capability
let APP_VERSION = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
let BUILD_MARKER: String = {
    guard
        let executableURL = Bundle.main.executableURL,
        let resourceValues = try? executableURL.resourceValues(forKeys: [.contentModificationDateKey]),
        let buildDate = resourceValues.contentModificationDate
    else {
        return "unknown build"
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: buildDate)
}()
let OUTPUT_FORMATS: [String] = [
    "HTML",
    "PDF",
    "TEX",
    "MD",
    "RTF",
    "TXT",
]
let OUTPUT_TYPES: [String] = [
    "Folder",
    "TAR Archive",
    "ZIP Archive",
]
// Page types
let PAGE_US_LETTER: (width: Int, height: Int) = (612, 792)
let PAGE_US_LEGAL: (width: Int, height: Int) = (612, 1008)
let PAGE_US_TABLOID: (width: Int, height: Int) = (792, 1224)
let PAGE_A4: (width: Int, height: Int) = (595, 842)
// Logger
extension Logger {
    /// Using your bundle identifier is a great way to ensure a unique identifier.
    private static var subsystem = Bundle.main.bundleIdentifier!

    static let noteQuery = Logger(subsystem: subsystem, category: "notequery")
    static let noteExport = Logger(subsystem: subsystem, category: "noteexport")
}

extension Scene {
    func windowResizabilityContentSize() -> some Scene {
        if #available(macOS 13.0, *) {
            return windowResizability(.contentSize)
        } else {
            return self
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

fileprivate struct LaunchExportOptions {
    let outputURL: URL
    let format: ExportFormat
    let incrementalSync: Bool
    let includeAttachments: Bool
    let quitWhenDone: Bool

    static func parse(arguments: [String]) -> LaunchExportOptions? {
        let hasExportFlag = arguments.contains("--export")
        let hasExportOptions = arguments.contains("--output") || arguments.contains("--format") || arguments.contains("--incremental")
        guard hasExportFlag || hasExportOptions else {
            return nil
        }

        var outputPath: String?
        var format: ExportFormat = .markdown
        var incrementalSync = false
        var includeAttachments = true
        var quitWhenDone = true

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--output":
                if index + 1 < arguments.count {
                    outputPath = arguments[index + 1]
                    index += 1
                }
            case "--format":
                if index + 1 < arguments.count {
                    format = exportFormat(from: arguments[index + 1]) ?? format
                    index += 1
                }
            case "--incremental":
                incrementalSync = true
            case "--no-incremental":
                incrementalSync = false
            case "--attachments":
                includeAttachments = true
            case "--no-attachments":
                includeAttachments = false
            case "--keep-open":
                quitWhenDone = false
            default:
                break
            }
            index += 1
        }

        guard let outputPath, !outputPath.isEmpty else {
            writeStandardError("Apple Notes Exporter: --output is required for command-line export.")
            return nil
        }

        return LaunchExportOptions(
            outputURL: URL(fileURLWithPath: NSString(string: outputPath).expandingTildeInPath),
            format: format,
            incrementalSync: incrementalSync,
            includeAttachments: includeAttachments,
            quitWhenDone: quitWhenDone
        )
    }

    private static func exportFormat(from rawValue: String) -> ExportFormat? {
        switch rawValue.lowercased() {
        case "html": return .html
        case "pdf": return .pdf
        case "tex", "latex": return .tex
        case "md", "markdown": return .markdown
        case "rtf": return .rtf
        case "txt", "text": return .txt
        default: return ExportFormat(rawValue: rawValue.uppercased())
        }
    }
}

fileprivate func writeStandardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

fileprivate func finishLaunchExport(_ options: LaunchExportOptions, status: Int32) {
    guard options.quitWhenDone else { return }

    if status == 0 {
        NSApp.terminate(nil)
    } else {
        exit(status)
    }
}

// MARK: - App State (Legacy Compatibility Layer)
// This class provides compatibility with the old UI while we migrate to ViewModels
@MainActor
class AppleNotesExporterState: ObservableObject {
    @Published var showProgressWindow: Bool = false
    @Published var exportPercentage: Float = 0.0
    @Published var exportMessage: String = "Exporting..."
    @Published var exporting: Bool = false
    @Published var shouldCancelExport: Bool = false
    @Published var exportDone: Bool = false
    @Published var selectedNotesCount: Int = 0
    @Published var fromAccountsCount: Int = 0
    @Published var licenseAccepted: Bool = UserDefaults.standard.bool(forKey: "licenseAcceptedGPLv3")

    // Action triggers (set from menu commands, observed by view)
    @Published var triggerSelectNotes: Bool = false
    @Published var triggerChooseFolder: Bool = false
    @Published var triggerExport: Bool = false

    // Export Log Window reference
    var exportLogWindow: NSWindow?

    // References to the new ViewModels
    let notesViewModel: NotesViewModel
    let exportViewModel: ExportViewModel

    init(notesViewModel: NotesViewModel, exportViewModel: ExportViewModel) {
        self.notesViewModel = notesViewModel
        self.exportViewModel = exportViewModel

        // Update counts from ViewModel
        updateCounts()
    }

    func showExportLog() {
        // Check if window already exists and bring to front
        if let window = exportLogWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Create new window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Export Log"
        window.minSize = NSSize(width: 500, height: 400)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .fullScreenDisallowsTiling]

        // Create content view with close handler
        let contentView = ExportLogView(onClose: {
            window.close()
        })
        .environmentObject(exportViewModel)

        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.makeKeyAndOrderFront(nil)

        exportLogWindow = window
    }

    func update() {
        updateCounts()
    }

    func refresh() {
        objectWillChange.send()
    }

    func reload() {
        // Cannot reload while exporting
        if self.exporting {
            return
        }

        Task {
            await notesViewModel.reload()
            await MainActor.run {
                updateCounts()
            }
        }
    }

    fileprivate func runLaunchExport(_ options: LaunchExportOptions) async {
        guard licenseAccepted else {
            writeStandardError("Apple Notes Exporter: license and Full Disk Access setup must be completed in the app before command-line export can run.")
            finishLaunchExport(options, status: 1)
            return
        }

        await notesViewModel.reload()
        updateCounts()

        if let errorMessage = notesViewModel.loadingState.errorMessage {
            writeStandardError("Apple Notes Exporter: unable to load Apple Notes. \(errorMessage)")
            finishLaunchExport(options, status: 1)
            return
        }

        let notes = notesViewModel.selectedNotes
        guard !notes.isEmpty else {
            writeStandardError("Apple Notes Exporter: no notes were found to export.")
            finishLaunchExport(options, status: 1)
            return
        }

        exportViewModel.configurations.incrementalSync = options.incrementalSync
        exportViewModel.configurations.includeAttachments = options.includeAttachments
        exportViewModel.saveConfigurations()

        await exportViewModel.exportNotes(
            notes,
            toDirectory: options.outputURL,
            format: options.format,
            includeAttachments: options.includeAttachments
        )

        switch exportViewModel.exportState {
        case .completed(let statistics):
            print("Apple Notes Exporter: exported \(statistics.successfulNotes) notes, \(statistics.failedNotes) failed notes, \(statistics.failedAttachments) failed attachments.")
            if !statistics.passwordProtectedNoteTitles.isEmpty {
                let count = statistics.passwordProtectedNoteTitles.count
                print("Apple Notes Exporter: found \(count) locked/password-protected note\(count == 1 ? "" : "s"); body content is unavailable until unlocked in Apple Notes.")
                for title in statistics.passwordProtectedNoteTitles {
                    print("Apple Notes Exporter: locked note: \(title)")
                }
            }
            finishLaunchExport(options, status: statistics.failedNotes == 0 && statistics.failedAttachments == 0 ? 0 : 1)
        case .error(let message):
            writeStandardError("Apple Notes Exporter: export failed. \(message)")
            finishLaunchExport(options, status: 1)
        case .cancelled:
            writeStandardError("Apple Notes Exporter: export cancelled.")
            finishLaunchExport(options, status: 1)
        default:
            finishLaunchExport(options, status: 1)
            break
        }
    }

    private func updateCounts() {
        selectedNotesCount = notesViewModel.selectedCount

        // Count unique accounts from selected notes
        let uniqueAccounts = Set(notesViewModel.selectedNotes.map { $0.accountId })
        fromAccountsCount = uniqueAccounts.count
    }
}

@main
struct Apple_Notes_ExporterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // New ViewModels
    @StateObject private var notesViewModel = NotesViewModel()
    @StateObject private var exportViewModel = ExportViewModel()
    @State private var didRunLaunchExport = false

    // Legacy compatibility state
    @ObservedObject var sharedState: AppleNotesExporterState
    private let launchExportOptions: LaunchExportOptions?

    init() {
        launchExportOptions = LaunchExportOptions.parse(arguments: ProcessInfo.processInfo.arguments)

        // Initialize ViewModels first
        let notesVM = NotesViewModel()
        let exportVM = ExportViewModel()

        // Create compatibility layer
        let state = AppleNotesExporterState(
            notesViewModel: notesVM,
            exportViewModel: exportVM
        )

        self.sharedState = state
        self._notesViewModel = StateObject(wrappedValue: notesVM)
        self._exportViewModel = StateObject(wrappedValue: exportVM)
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            if let launchExportOptions {
                SwiftUI.Color.clear
                    .frame(width: 1, height: 1)
                    .onAppear {
                        guard !didRunLaunchExport else { return }
                        didRunLaunchExport = true
                        Task {
                            await sharedState.runLaunchExport(launchExportOptions)
                        }
                    }
            } else {
                AppleNotesExporterView(sharedState: sharedState)
                    .environmentObject(notesViewModel)
                    .environmentObject(exportViewModel)
                    .onAppear {
                        NSWindow.allowsAutomaticWindowTabbing = false
                    }
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(action: {
                    sharedState.reload()
                }) {
                    Text("Reload Notes Accounts")
                }
                .keyboardShortcut("R", modifiers: [.command])
                .disabled(sharedState.exporting)
            }

            CommandGroup(after: .sidebar) {
                Toggle(isOn: Binding(
                    get: { notesViewModel.foldersOnTop },
                    set: { newValue in
                        notesViewModel.foldersOnTop = newValue
                        Task {
                            await notesViewModel.rebuildHierarchy()
                        }
                    }
                )) {
                    Text("Display Folders Separately")
                }

                Picker("Sort By", selection: Binding(
                    get: { notesViewModel.sortOption },
                    set: { newValue in
                        notesViewModel.sortOption = newValue
                        Task {
                            await notesViewModel.rebuildHierarchy()
                        }
                    }
                )) {
                    ForEach(NoteSortOption.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.inline)
            }

            CommandGroup(after: .newItem) {
                let canInteract = sharedState.licenseAccepted && !sharedState.exporting

                // Format selection: Cmd+1 through Cmd+6
                Button("HTML Format") {
                    UserDefaults.standard.set("HTML", forKey: "outputFormat")
                }
                .keyboardShortcut("1", modifiers: [.command])
                .disabled(!canInteract)

                Button("PDF Format") {
                    UserDefaults.standard.set("PDF", forKey: "outputFormat")
                }
                .keyboardShortcut("2", modifiers: [.command])
                .disabled(!canInteract)

                Button("LaTeX Format") {
                    UserDefaults.standard.set("TEX", forKey: "outputFormat")
                }
                .keyboardShortcut("3", modifiers: [.command])
                .disabled(!canInteract)

                Button("Markdown Format") {
                    UserDefaults.standard.set("MD", forKey: "outputFormat")
                }
                .keyboardShortcut("4", modifiers: [.command])
                .disabled(!canInteract)

                Button("RTF Format") {
                    UserDefaults.standard.set("RTF", forKey: "outputFormat")
                }
                .keyboardShortcut("5", modifiers: [.command])
                .disabled(!canInteract)

                Button("Plain Text Format") {
                    UserDefaults.standard.set("TXT", forKey: "outputFormat")
                }
                .keyboardShortcut("6", modifiers: [.command])
                .disabled(!canInteract)

                Divider()

                Button("Select Notes...") {
                    sharedState.triggerSelectNotes = true
                }
                .keyboardShortcut("a", modifiers: [.command])
                .disabled(!canInteract)

                Button("Choose Output Folder...") {
                    sharedState.triggerChooseFolder = true
                }
                .keyboardShortcut("o", modifiers: [.command])
                .disabled(!canInteract)

                Button("Export") {
                    sharedState.triggerExport = true
                }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(!canInteract)

                Divider()
            }

            CommandGroup(after: .windowArrangement) {
                Button(action: {
                    sharedState.showExportLog()
                }) {
                    Text("Show Export Log")
                }
                .keyboardShortcut("L", modifiers: [.command, .shift])
                .disabled(!sharedState.licenseAccepted)
            }
        }
        .windowResizabilityContentSize()
    }
}
