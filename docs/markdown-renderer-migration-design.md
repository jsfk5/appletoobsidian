# Markdown Renderer Migration Design

Apple to Obsidian occasionally needs to correct how unchanged Apple Notes content is rendered into Markdown. Examples include ordered-list numbering, HTML text escaping, safe link handling, and future checklist syntax.

These corrections should improve new exports without making an ordinary incremental sync unexpectedly rewrite the entire vault.

## Status

This document defines the migration contract. The user-facing migration control and manifest field described below are not implemented yet. Renderer changes remain on the selective-adoption branch until this contract has focused tests and a temporary-export validation pass.

## The Problem

Incremental sync currently decides whether a note changed from Apple Notes metadata, content fingerprints, export settings, and exported-artifact checks. Rich HTML is generated later, during export.

The planner therefore cannot cheaply identify which unchanged notes contain a renderer feature affected by a correction. Adding a renderer version to every existing content or settings fingerprint would make every manifest entry look changed and silently re-export the full library.

## Migration Contract

1. Normal incremental sync never refreshes unchanged notes solely because the renderer changed.
2. New and genuinely changed notes use the current renderer immediately.
3. Each successful Markdown export records the renderer version used for that manifest entry.
4. Missing or older renderer versions are reported as eligible for refresh, not automatically selected.
5. Refreshing eligible notes requires an explicit one-time user action.
6. A failed or cancelled refresh does not mark an unexported note as current.
7. A second normal incremental run after a successful refresh exports zero unchanged notes.

## Proposed Manifest Field

Add an optional renderer identifier to each synced-note entry, separate from the note content fingerprint and export-settings fingerprint:

    {
      "markdownRendererVersion": "markdown-v2"
    }

The field is optional so existing manifests remain readable. Older app builds ignore the additional JSON field. A renderer version is recorded only after that note is written successfully.

Renderer eligibility is evaluated only for Markdown exports in the selected output root. Other export formats do not become stale because the Markdown renderer changes.

## Proposed Controls

Command line:

    --refresh-renderer
    --dry-run

Using both flags reports the number of eligible notes and planned paths without writing or deleting files. The refresh flag by itself performs the explicit one-time refresh while retaining normal output-root and cleanup guards.

The existing nightly script does not include either flag, so scheduled incremental sync remains unchanged.

The future UI should present a one-time command such as **Refresh Markdown for exporter updates**, show the eligible-note count, explain that existing Markdown files will be rewritten from Apple Notes, and require deliberate confirmation.

## Validation Gate

Before renderer migration reaches the installed app:

- Prove a normal incremental run does not select unchanged legacy entries.
- Prove dry-run reports eligible notes without changing files or the manifest.
- Prove explicit refresh selects only stale Markdown entries.
- Prove successful notes receive the current renderer version.
- Prove failed notes remain eligible.
- Prove a second incremental run exports zero unchanged notes.
- Run against a temporary export root before replacing the stable app.

Until these gates pass, renderer corrections may be reviewed and tested on a branch but must not be merged into the installed personal workflow.
