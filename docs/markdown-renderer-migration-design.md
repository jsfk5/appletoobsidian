# Markdown Renderer Migration Design

Apple to Obsidian occasionally needs to correct how unchanged Apple Notes content is rendered into Markdown. Examples include ordered-list numbering, HTML text escaping, safe link handling, and future checklist syntax.

These corrections should improve new exports without making an ordinary incremental sync unexpectedly rewrite the entire vault.

## Status

The command-line migration control and optional manifest field are implemented on `codex/selective-upstream-adoption`. The automated migration gate passes, but the branch still needs a temporary-export validation pass before it is merged or installed for a personal workflow. A future UI control is not implemented yet.

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

## Manifest Field

Add an optional renderer identifier to each synced-note entry, separate from the note content fingerprint and export-settings fingerprint:

    {
      "markdownRendererVersion": "markdown-v2"
    }

The field is optional so existing manifests remain readable. Older app builds ignore the additional JSON field. A renderer version is recorded only after that note is written successfully.

Renderer eligibility is evaluated only for Markdown exports in the selected output root. Other export formats do not become stale because the Markdown renderer changes.

## Command-Line Controls

Command line:

    --refresh-renderer
    --dry-run
    --obsidian-links
    --no-obsidian-links

Using both flags reports the number of eligible notes and planned paths without writing or deleting files. The refresh flag by itself performs the explicit one-time refresh while retaining normal output-root and cleanup guards.

Example preview:

    "/Applications/Apple Notes Exporter.app/Contents/MacOS/Apple Notes Exporter" \
      --output "/path/to/temporary/Apple Notes" \
      --format markdown \
      --obsidian-links \
      --refresh-renderer \
      --dry-run

Example one-time refresh after reviewing the preview:

    "/Applications/Apple Notes Exporter.app/Contents/MacOS/Apple Notes Exporter" \
      --output "/path/to/temporary/Apple Notes" \
      --format markdown \
      --obsidian-links \
      --refresh-renderer

`--refresh-renderer` implies incremental mode and requires an existing sync manifest. Renderer refresh is rejected for non-Markdown formats. `--dry-run` currently requires `--refresh-renderer`.

`--obsidian-links` and `--no-obsidian-links` explicitly control Apple Notes link conversion for command-line exports. If neither is present, the app retains its saved setting for backward compatibility. Validation candidates use a separate preference domain, so their commands should always pass the setting that matches the copied manifest.

The existing nightly script does not include the renderer-refresh flags, so scheduled incremental sync remains unchanged.

The future UI should present a one-time command such as **Refresh Markdown for exporter updates**, show the eligible-note count, explain that existing Markdown files will be rewritten from Apple Notes, and require deliberate confirmation.

## Validation Gate

Automated checks completed on 2026-07-22:

- A normal incremental run does not select unchanged legacy entries.
- Dry-run reports eligible notes without changing files, orphan artifacts, or the manifest.
- Explicit refresh selects stale Markdown entries while leaving current entries alone.
- Successful notes receive the current renderer version.
- Failed or cancelled notes remain eligible because renderer state is recorded per successful note.
- A successful refresh settles to both a normal incremental no-op and a second refresh no-op.
- Legacy manifests without the renderer field remain readable.

Remaining manual gate:

- Run dry-run, explicit refresh, and a second normal incremental no-op against a temporary export root before replacing the stable app.

Until the temporary-output gate passes, renderer corrections must not be merged into the installed personal workflow.
