# Apple Notes Feature Coverage

This document tracks Apple Notes features against Apple to Obsidian export and sync behavior. It is a compatibility matrix and test plan, not a guarantee of full fidelity.

The source feature inventory comes from Apple's Notes User Guide for Mac. Apple Notes can change its local storage format across macOS releases, so every supported feature needs either regression coverage, manual validation, or a clearly documented limitation.

## Status Legend

- **Supported**: Implemented and expected to work for normal use.
- **Partial**: Some behavior works, but fidelity or edge cases are known gaps.
- **Needs test**: Code likely handles it, but the repo needs focused regression coverage.
- **Unknown**: Not yet audited against current Apple Notes data.
- **Unsupported**: Known not to export in a useful Obsidian form today.

## Coverage Matrix

| Apple Notes feature | Desired Obsidian output | Current status | Sync concern | Test status | Next action |
|---|---|---|---|---|---|
| Plain text | Markdown text | Supported | Content changes should trigger export | Needs test | Add basic markdown fixture test |
| Headings and paragraph styles | Markdown headings and text blocks | Partial | Content changes should trigger export | Needs test | Verify headings, subheadings, title, body |
| Bold, italic, underline, strikethrough | Markdown or safe HTML where Markdown has no equivalent | Partial | Content changes should trigger export | Needs test | Add formatting fixture with expected Markdown |
| Highlights and text color | Preserve useful styling or degrade predictably | Unknown | Content changes should trigger export | Not covered | Audit Apple Notes HTML output |
| Collapsible sections | Preserve heading/content text; represent collapsed state if possible | Unknown | Content changes should trigger export | Not covered | Research local representation |
| Bulleted lists | Markdown list syntax | Partial | Content changes should trigger export | Needs test | Add nested bullet fixture |
| Numbered lists | Markdown ordered list syntax | Partial | Content changes should trigger export | Needs test | Add nested numbered-list fixture |
| Checklists | Markdown task list syntax with checked/unchecked state | Unknown | Reordering/checking should trigger export | Not covered | Add checklist fixture and sync test |
| Tables | Markdown table or safe HTML table | Partial | Cell edits should trigger export | Needs test | Add multiline and linked-cell table fixtures |
| Web links | Markdown links | Supported | Link URL/title changes should trigger export | Needs test | Add web-link fixture |
| Apple Notes note links | Obsidian wikilinks to exported target notes | Supported | Target title/path changes must update links | Needs test | Add renamed/moved linked-note tests |
| App links and deep links | Markdown links when safe | Unknown | URL changes should trigger export | Not covered | Audit URL schemes and escaping |
| Photos and images | Exported attachment plus inline Obsidian image embed | Supported | Attachment edits/replacements should trigger export | Partial | Add multiple image formats fixture |
| Generic file attachments | Exported attachment folder with Markdown link | Partial | Attachment add/remove should trigger export | Needs test | Add file attachment fixture |
| PDFs | Exported PDF attachment with Markdown link or embed | Partial | PDF replacement/markup should trigger export | Needs test | Add PDF fixture |
| Scanned documents | Export scan as attachment, ideally PDF/image with useful link | Unknown | Scan add/remove/markup should trigger export | Not covered | Audit local scan representation |
| Drawings | Export drawing image/file with useful Markdown reference | Partial | Drawing edits should trigger export | Needs test | Add drawing fixture |
| Marked-up attachments | Export latest attachment state | Unknown | Markup edits should trigger export | Not covered | Audit whether modified file path changes |
| Webpage previews | Preserve link and useful preview text if available | Unknown | Preview metadata changes are low priority | Not covered | Decide link-only vs preview export |
| Map locations | Preserve link or location attachment where available | Unknown | Location changes should trigger export | Not covered | Audit local representation |
| Audio recordings | Export audio attachment with Markdown link | Unknown | Audio add/remove should trigger export | Not covered | Audit audio attachment storage |
| Audio transcripts | Export transcript into Markdown or sidecar file if available locally | Unknown | Transcript generation/edits should trigger export | Not covered | Research transcript storage |
| Math Notes | Preserve visible expression/result text where possible | Unknown | Calculation changes should trigger export | Not covered | Audit Math Notes local data |
| Folders and subfolders | Matching folder tree under output root | Supported | Folder moves must trigger path update | Manual validation | Add move regression test |
| Moved notes | Markdown file relocates to new exported folder path | Supported | Folder/account ID must affect fingerprint | Manual validation | Add regression test for folder/account fingerprint |
| Deleted notes | Previously exported file and associated folders are pruned | Supported | Must not delete outside output root | Manual validation | Add cleanup safety tests |
| Recently Deleted | Do not export; prune prior export when applicable | Supported | Folder detection must remain correct | Needs test | Add Recently Deleted filter test |
| Pins | Optional metadata, not physical folder placement | Unknown | Pin/unpin should not force destructive path changes | Not covered | Decide whether to export as frontmatter |
| Tags | Obsidian tags or frontmatter metadata | Unknown | Tag edits should trigger export if supported | Not covered | Research tag storage and metadata format |
| Smart Folders | Documented as virtual folders; avoid duplicate physical exports | Unknown | Smart Folder changes should not duplicate notes | Not covered | Treat source folder as canonical path |
| Locked/password-protected notes | Export title and placeholder only, log locked note titles, and avoid treating blank body as normal content | Partial | Lock/unlock state should affect fingerprint without blocking sync | Not covered | Add locked-note logging/reporting and placeholder tests |
| Shared notes and folders | Export readable content; optional sharing metadata | Unknown | Shared note moves/permission changes may affect availability | Not covered | Audit shared notes in local DB |
| Mentions/collaboration activity | Preserve visible text; activity metadata likely unsupported | Unknown | Collaboration metadata changes low priority | Not covered | Document unsupported metadata if absent |
| Imported notes | Export same as normal notes once in Apple Notes database | Unknown | Imported folder/name changes should sync normally | Not covered | Test imported sample note |

## Near-Term Test Plan

1. Prove cleanup cannot delete outside the selected output root.
2. Prove moved notes update exported paths when `accountId` or `folderId` changes.
3. Prove deleted notes are pruned from the export folder.
4. Prove Recently Deleted notes are skipped and prior exports are removed.
5. Prove checklists preserve checked and unchecked state.
6. Prove Apple Notes links become Obsidian wikilinks after target notes are renamed or moved.
7. Prove image attachments export and embed inline in Obsidian Markdown.
8. Prove PDF and generic file attachments are linked without breaking the note body.
9. Prove title normalization preserves display meaning while keeping filesystem-safe paths.
10. Prove locked/password-protected notes export a clear placeholder and are listed in logs or export summary by title.

## Current Priorities

1. Add regression tests for existing supported sync behavior before changing deletion or move logic.
2. Audit unknown Apple Notes features with small synthetic notes, not private user notes.
3. Document unsupported metadata honestly instead of implying full Apple Notes parity.
4. Keep all cleanup behavior scoped to the selected output root.
5. Keep the personal installed app stable until public changes are intentionally built, installed, and validated.

## Source References

- Apple Notes User Guide for Mac: https://support.apple.com/guide/notes/welcome/mac
- Get started with Notes on Mac: https://support.apple.com/guide/notes/get-started-apd441e46563/mac
- Format notes on Mac: https://support.apple.com/guide/notes/apd1955d3b21/mac
- Add lists in Notes on Mac: https://support.apple.com/guide/notes/apd93c815aa0/mac
- Add links in Notes on Mac: https://support.apple.com/guide/notes/apde615d29c2/mac
- Add photos, PDFs, and more in Notes on Mac: https://support.apple.com/guide/notes/not95edd2813/mac
- Record and transcribe audio in Notes on Mac: https://support.apple.com/guide/notes/apdb5106e334/mac
- Use Smart Folders in Notes on Mac: https://support.apple.com/guide/notes/apd58edc7964/mac
