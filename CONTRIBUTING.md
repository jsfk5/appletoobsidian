# Contributing

Thanks for your interest in Apple to Obsidian.

This project is a GPL-3.0 fork of Apple Notes Exporter focused on one workflow: exporting and syncing Apple Notes into an Obsidian vault with reliable Markdown, attachments, note links, and mirror-style cleanup.

The app bundle and Xcode scheme are still named `Apple Notes Exporter` while the fork is being stabilized. Avoid broad rename changes unless they are part of an explicit release-prep task, because bundle identity changes can affect Full Disk Access and scheduled sync workflows.

## Before You Start

- Read [README.md](README.md), [PRIVACY.md](PRIVACY.md), [SECURITY.md](SECURITY.md), and [docs/apple-notes-feature-coverage.md](docs/apple-notes-feature-coverage.md).
- Use synthetic notes or redacted test data whenever possible.
- Do not test destructive sync behavior against an important vault without a backup.
- Keep changes small and focused.
- Prefer docs and tests before changing sync deletion, attachment path, or database parsing behavior.

## Getting Set Up

1. Fork the repo and clone your fork.
2. Open `Apple Notes Exporter/Apple Notes Exporter.xcodeproj` in Xcode.
3. Grant Full Disk Access to the exact app bundle you run if you need to read the local Apple Notes database.
4. Build and run:

```sh
make build      # Debug build
make run        # Build and launch
make test       # Run tests
make clean      # Clean build artifacts
make logs       # Stream app logs
```

The project can also be built directly with Xcode:

```sh
xcodebuild \
  -project "Apple Notes Exporter/Apple Notes Exporter.xcodeproj" \
  -scheme "Apple Notes Exporter" \
  -configuration Debug \
  build
```

## Project Layout

```text
Apple Notes Exporter/
  Apple Notes Exporter/
    AppleNotesExporterApp.swift          # App entry point and launch export handling
    AppleNotesExporterView.swift         # Main SwiftUI UI
    AppleNotesKit/                       # C parser for Apple Notes database access
    Repository/NotesRepository.swift     # Swift repository layer around AppleNotesKit
    ViewModels/ExportViewModel.swift     # Export, sync, cleanup, and progress logic
    ViewModels/NotesViewModel.swift      # Notes loading and selection state
    Models/NotesNote+Export.swift        # Markdown/HTML/RTF/TEX/TXT conversion helpers
    Models/SyncManifest.swift            # Incremental sync manifest
    HTMLAttachmentProcessor.swift        # Attachment placeholder repair and export support
    NoteHTMLGenerator.swift              # Protobuf note body to HTML generation
    TableParser.swift                    # Table protobuf to HTML/Markdown support
    notestore.pb.swift                   # Generated protobuf models
  Apple Notes ExporterTests/
    Apple_Notes_ExporterTests.swift      # Focused export/sync regression tests
docs/
  apple-notes-feature-coverage.md        # Feature coverage and test matrix
```

## Safety Rules

Do not commit or upload:

- Apple Notes databases
- exported notes or vault folders
- private logs
- screenshots that show private note contents
- personal filesystem paths
- credentials, keys, tokens, passwords, or API keys
- generated app bundles, `Products/`, `DerivedData/`, `.xcresult`, or coverage profiles
- local-only agent or project-memory files

Before every public commit, scan the staged files for sensitive data and generated artifacts. Prefer explicit staging over `git add .`.

## High-Risk Areas

Treat these areas as requiring extra review and focused tests:

- deletion and cleanup logic
- output-root path guards
- incremental sync fingerprints
- Apple Notes database schema handling
- attachment file discovery and path resolution
- Obsidian wikilink conversion
- title normalization versus displayed note titles
- Full Disk Access diagnostics
- command-line and scheduled sync behavior

If a change can delete, move, or overwrite user files, include a test or a clear manual validation plan.

## Reporting Bugs

When filing an issue, include:

- macOS version
- app version, build, or commit hash
- export format
- whether Full Disk Access is enabled
- whether the issue appears in a temporary test export folder
- redacted log output, if relevant
- a synthetic reproduction note, if possible

For sync bugs, include:

- whether the source note was created, edited, moved, deleted, or moved to Recently Deleted
- expected exported path
- actual exported path
- whether attachments or resource folders were involved

For attachment and link bugs, include:

- attachment type
- expected Markdown output
- actual Markdown output
- whether the target file exists in the exported attachment folder

Do not attach private notes, databases, full vaults, or unredacted screenshots to public issues.

## Before Opening a Pull Request

1. Keep the PR focused on one behavior or documentation improvement.
2. Run `git diff --check`.
3. Build or test where practical.
4. Confirm no private data or generated artifacts are staged.
5. Explain the user-facing behavior change.
6. Call out any sync, cleanup, or Full Disk Access risk.
7. Link to the relevant row in `docs/apple-notes-feature-coverage.md` when applicable.

Docs-only PRs do not need an app build, but they should still pass `git diff --check` and the sensitive-data check.

## Commit Messages

Use Conventional Commits:

- `fix:` bug fix
- `feat:` new feature
- `refactor:` restructuring without behavior change
- `docs:` documentation
- `chore:` build/dependency/maintenance
- `style:` formatting or whitespace
- `test:` adding or fixing tests
- `perf:` performance improvement

Examples:

```text
docs: update contributing guide for Obsidian fork
test: cover moved note sync fingerprint
fix(sync): keep cleanup inside output root
feat(markdown): export Apple Notes tags as frontmatter
```

## Contributors

If your PR is merged, add yourself to `CONTRIBUTORS.txt`:

```text
- Your Name (GitHub: @yourusername) - What you contributed.
```

## License

By contributing, you agree that your work will be licensed under the project's [GNU General Public License v3.0](LICENSE).
