# Selective Upstream Adoption Strategy

Apple to Obsidian began as a GPL-3.0 fork of Apple Notes Exporter, but it now has a narrower product direction of its own. The project is focused on one workflow: moving and continuously syncing Apple Notes into Obsidian with reliable Markdown, folder structure, attachments, note links, and mirror-style cleanup.

The project does not aim to mirror every upstream feature or merge every upstream release. Upstream remains an important source of research, fixes, and implementation ideas. Changes are adopted only when they strengthen the Apple Notes-to-Obsidian workflow and can be integrated without weakening sync safety.

## Product Boundary

Apple to Obsidian prioritizes:

- Obsidian-compatible Markdown.
- Apple Notes folder and subfolder preservation.
- Inline images and durable attachment links.
- Apple Notes links rewritten as Obsidian wikilinks.
- Incremental sync that detects content, settings, account, and folder changes.
- Mirror cleanup for deleted and moved notes.
- Recently Deleted exclusion.
- A dependable scheduled export path.
- Clear diagnostics for locked notes and macOS privacy permissions.
- A future Apple to Obsidian-specific UI and setup experience.

General-purpose document conversion is not the product goal. Additional formats or integrations are considered only when they directly support migration, backup, interoperability, or project maintenance.

## Upstream Checkpoint Reviewed

The project reviewed upstream through [`c0ddf926`](https://github.com/kzaremski/apple-notes-exporter/commit/c0ddf926eabcea679286a32f897a22a4f01c1e25) on 2026-07-10.

That upstream line includes useful work such as a dedicated CLI, CI, safer HTML generation, title-column compatibility, gallery attachment fixes, release hygiene, App Intents, MCP support, and additional export formats. These changes are candidates for review, not an automatic merge queue.

## Adoption Rules

1. Do not merge upstream `main` wholesale merely to reduce divergence.
2. Review the specific upstream change and the problem it solves.
3. Port or cherry-pick the smallest useful implementation slice.
4. Preserve upstream authorship and GPL-3.0 attribution.
5. Add focused tests before changing export, sync, cleanup, or database behavior.
6. Keep each adoption small enough to review and revert independently.
7. Do not replace a known-working local app or automation path until the candidate passes its validation gates.

## High-Value Candidates

| Upstream area | Potential value here | Required gate |
|---|---|---|
| HTML text escaping and safe link handling | Better fidelity and safer generated output | Formatting and link regression tests |
| Note and folder title-column compatibility | Better support across Apple Notes database versions and handwritten-note titles | Synthetic schema fixtures and normal-title regression tests |
| Gallery and fallback attachment resolution | Better On My Mac and cross-account attachment fidelity | Image, gallery, and extension-detection fixtures |
| Test-host suppression and CI | More reliable automated validation | Clean local build and passing public CI |
| Repository and signing hygiene | Easier contribution and release preparation | No change to runtime bundle identity during maintenance |
| Dedicated CLI architecture | Cleaner long-term automation interface | Backward-compatible transition plan and nightly sync validation |

The existing fork already has stronger behavior in several areas, including move-sensitive fingerprints, Recently Deleted filtering, Obsidian wikilinks, locked-note placeholders, visual slash preservation, and guarded mirror cleanup. Upstream implementations in overlapping areas must be compared against these guarantees rather than replacing them by default.

## Not Adopted By Default

The following upstream directions are outside the current core scope unless a concrete Apple Notes-to-Obsidian use case justifies them:

- Broad document-format expansion.
- Upstream UI and branding decisions.
- App Intents and Shortcuts features.
- MCP server functionality.
- DOCX, ODT, EPUB, and general office-document workflows.
- Structural refactors that do not improve the focused workflow.

These are not permanent rejections. They require their own product, privacy, maintenance, and testing case.

## Workflow Protection Gates

Before a runtime adoption reaches the stable app path, it must preserve or prove:

- Existing incremental manifests do not trigger unrelated full re-exports.
- A second unchanged sync exports zero notes.
- Moved notes relocate to the correct Obsidian folder.
- Deleted and Recently Deleted notes are pruned safely.
- Cleanup cannot reach outside the selected output root.
- Images and file attachments still resolve from exported Markdown.
- Apple Notes links still become valid Obsidian wikilinks.
- Locked notes remain readable placeholders without leaking unavailable body data.
- The scheduled command-line workflow still exits correctly and reports failures.

Runtime candidates should first use synthetic notes and a temporary export root. Replacing an installed app, changing its bundle identity, or migrating scheduled automation happens only after those gates pass.

Renderer corrections also need an explicit migration path for already-exported notes. The project must not hide a global refresh inside a normal incremental run. See [Markdown Renderer Migration Design](markdown-renderer-migration-design.md) for the proposed opt-in manifest and user-control contract.

## UI And Product Direction

The current app bundle and much of the interface still reflect Apple Notes Exporter. That is transitional. Apple to Obsidian will eventually have its own UI and UX centered on Obsidian vault selection, sync status, safe cleanup previews, attachment diagnostics, locked-note reporting, and scheduled operation.

The UI transition is separate from exporter correctness. Export and sync behavior must remain stable while the product identity evolves.

## License And Attribution

Apple to Obsidian remains licensed under GNU GPL v3. Upstream code that is reused or adapted remains under compatible GPL terms, with original authorship and relevant third-party attribution preserved.
