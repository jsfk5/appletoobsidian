# Privacy

Apple to Obsidian is designed to run locally on your Mac.

## What the app reads

The app reads local Apple Notes database files and related attachment files that macOS stores on your machine. macOS requires Full Disk Access before the app can read those protected files.

## What the app writes

The app writes exported notes, attachments, resource folders, and an incremental sync manifest into the output folder you choose.

In sync mode, Apple Notes is treated as the source of truth. The app may remove previously exported Markdown files and attachment/resource folders inside the selected output folder when the corresponding source notes are deleted, moved out of scope, moved to Recently Deleted, or otherwise no longer part of the active export set.

## Network behavior

The exporter itself is intended to operate locally. It does not need a cloud service to export your notes. Build tools, package managers, GitHub, or development workflows may use the network separately when you build from source or work with the repository.

## Before first use

- Back up your Obsidian vault.
- Run the first export into a temporary test folder.
- Review the exported Markdown and attachments before syncing into an important vault.
- Use a dedicated Apple Notes export folder rather than mixing exported files with unrelated handwritten notes.

## Public bug reports

Do not attach private Apple Notes databases, exported notes, personal logs, screenshots with sensitive note content, or private vault files to public GitHub issues.

When reporting a bug, prefer:

- macOS version
- app version or commit
- export format
- whether Full Disk Access is enabled
- a small synthetic sample note if possible
- redacted logs
- a description of the folder structure rather than private file contents

## Warranty

This project is distributed under the GNU General Public License v3.0 and is provided without warranty. See [LICENSE](LICENSE).
