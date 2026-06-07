# Apple to Obsidian

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![macOS 11.0+](https://img.shields.io/badge/macOS-11.0%2B-brightgreen.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5-orange.svg)](https://swift.org/)
[![Last Commit](https://img.shields.io/github/last-commit/jsfk5/appletoobsidian)](https://github.com/jsfk5/appletoobsidian/commits/main)

Apple to Obsidian is a macOS app for exporting and continuously syncing Apple Notes into an Obsidian vault as Markdown, with folder structure, attachments, inline images, and Apple Notes note links preserved in an Obsidian-friendly form.

This repository is a GPL-3.0 fork of [kzaremski/apple-notes-exporter](https://github.com/kzaremski/apple-notes-exporter). The original project is a Swift macOS app for bulk exporting Apple Notes to multiple formats. This fork keeps that foundation, gives full credit to the upstream work, and focuses the roadmap specifically on one job: making Apple Notes to Obsidian migration and ongoing sync reliable.

## Why this fork exists

Apple Notes is excellent for quick capture, but many people want their long-term notes in a local Markdown knowledge base. A one-time export helps, but it is not enough when Apple Notes remains the daily inbox. This fork is tuned for that real workflow:

- keep writing and moving notes in Apple Notes
- run a repeatable sync into an Obsidian vault
- preserve note hierarchy and attachments
- convert Apple Notes links into Obsidian note links
- remove exported notes when the source notes are deleted or moved out of scope
- avoid exporting Apple Notes' Recently Deleted folder

The goal is not to become a general-purpose document exporter. The goal is to become the most dependable Apple Notes to Obsidian bridge.

## Current Obsidian-focused changes

Compared with the upstream Apple Notes Exporter base, this fork adds and/or tunes:

- Obsidian Markdown export mode with Apple Notes links converted to Obsidian wikilinks.
- Markdown image handling that emits Obsidian-friendly inline image references instead of leaving broken placeholder links.
- Attachment migration that writes files beside the exported note and keeps image references connected.
- Title and filename normalization for names that include characters like `/`, so display titles can preserve meaning while exported paths stay filesystem-safe.
- Incremental sync fingerprints that include export settings, note content, account, and folder identity.
- Move detection so notes moved between Apple Notes folders are relocated in the exported vault tree.
- Mirror-style stale cleanup for notes deleted from Apple Notes.
- Recently Deleted exclusion so deleted Apple Notes are not treated as active notes.
- Cleanup for untracked legacy Markdown exports and orphan attachment/resource folders under the configured export root.
- Safer automation behavior for nightly syncs using the app executable directly instead of click automation.
- More visible permission guidance when macOS Full Disk Access blocks the Notes database.
- Regression coverage for Obsidian link conversion, path normalization, sync cleanup, and move-sensitive fingerprints.

See [Apple Notes Feature Coverage](docs/apple-notes-feature-coverage.md) for the public compatibility matrix, sync concerns, and test priorities.

## Sync behavior

Incremental sync treats Apple Notes as the source of truth. On each sync, the exporter:

1. Reads the local Apple Notes database.
2. Skips notes in Recently Deleted.
3. Exports new or changed notes.
4. Re-exports notes when Obsidian-specific output settings or folder placement changed.
5. Removes stale files previously exported for notes that no longer exist in the active Apple Notes set.
6. Removes verified orphan attachment/resource folders inside the export root.

Cleanup is scoped to the configured output folder. The app should not touch files outside the selected export root.

## Data safety

Apple to Obsidian is provided without warranty. Sync mode treats Apple Notes as the source of truth and may remove previously exported Markdown files and attachment/resource folders inside the selected export folder.

Before using sync mode on important notes:

- Back up your Obsidian vault.
- Run the first export into a temporary test folder.
- Review the exported folder before pointing the app at your real vault.
- Keep the export root dedicated to Apple Notes output, not mixed with unrelated hand-written notes.
- Do not share private exported notes, logs, screenshots, or databases in public issues.

The project is designed so cleanup stays inside the selected output root. If you report a cleanup bug, describe the folder structure and logs without attaching private note contents.

## Requirements

- macOS Big Sur 11.0 or later
- Intel or Apple Silicon Mac
- Xcode for building from source
- Full Disk Access for the built app, because Apple Notes stores its data in protected local databases

## Build from source

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project "Apple Notes Exporter/Apple Notes Exporter.xcodeproj" \
  -scheme "Apple Notes Exporter" \
  -configuration Debug \
  -derivedDataPath /tmp/apple-notes-exporter-deriveddata \
  build
```

The app bundle remains named `Apple Notes Exporter.app` for now while the fork is being stabilized. A public-facing rename is part of the roadmap.

## Full Disk Access

macOS protects the Apple Notes database. If the app reports zero notes or fails with a SQLite authorization error, add the exact app bundle you are running to:

`System Settings -> Privacy & Security -> Full Disk Access`

If you replace the app in `/Applications`, macOS may require you to remove and re-add the new bundle.

## Automation

For nightly syncs, prefer running the built app or a wrapper script directly from a LaunchAgent. Do not automate the GUI with coordinate-based click tools; the app state and window position are too easy to break.

Example wrapper shape:

```sh
"/Applications/Apple Notes Exporter.app/Contents/MacOS/Apple Notes Exporter"
```

## Relationship to upstream

This fork starts from [Apple Notes Exporter](https://github.com/kzaremski/apple-notes-exporter), created by Konstantin Zaremski. The upstream project supports broad export formats and general Apple Notes export use cases. Apple to Obsidian narrows that into an Obsidian-first workflow and keeps the same GPL-3.0 license.

Upstream work, contributors, and research remain credited. Useful fixes here may be suitable for upstream pull requests where they also help the broader exporter.

## Open source maintenance focus

This repository is being published as an active GPL-3.0 fork with a concrete maintainer workflow:

- keep the project public and buildable
- document Apple Notes schema and permission pitfalls as they are discovered
- accept reproducible bug reports around broken note links, attachments, move detection, and sync cleanup
- use AI-assisted maintenance for code review, regression tests, release prep, and issue triage
- keep user data local; the exporter reads the macOS Notes database and writes Markdown files to a chosen local output folder

## Roadmap

- Rename the app bundle and UI from Apple Notes Exporter to Apple to Obsidian.
- Add a dedicated command-line sync command with explicit output arguments.
- Add release packaging and notarization for public downloads.
- Add a safer first-run setup flow for Obsidian vault selection.
- Expand tests around Apple Notes schema changes across macOS releases.
- Document known limitations with locked notes, shared notes, and non-iCloud accounts.

## Limitations

- Apple Notes is not a public export API. This project reads local Notes database files, so macOS and Apple Notes schema changes can break behavior.
- The app needs Full Disk Access.
- Email-backed Notes accounts may not live in the same local database shape as iCloud and On My Mac notes.
- Sync mode can remove previously exported files inside the selected output folder when the corresponding Apple Notes are deleted, moved out of scope, or no longer part of the active export set.
- This is not affiliated with Apple, Obsidian, or OpenAI.

## Privacy and security

See [PRIVACY.md](PRIVACY.md) for local-data handling notes and [SECURITY.md](SECURITY.md) for safe vulnerability reporting.

## License

This project is free software under the GNU General Public License v3.0. See [LICENSE](LICENSE) for the full license text.

Original project:

```text
Apple Notes Exporter
Copyright (C) 2026 Konstantin Zaremski
Licensed under the GNU General Public License v3.0
```

Fork-specific changes are made available under the same GPL-3.0 license.
