# Checklist Task List Syntax Design

Apple Notes checklists currently export to Markdown with the checked or unchecked state preserved as visible checkbox characters inside normal list items:

```markdown
- ☑ Finished item
- ☐ Open item
```

That is readable, but Obsidian understands native Markdown task-list syntax:

```markdown
- [x] Finished item
- [ ] Open item
```

This document defines the scoped design for converting Apple Notes checklist state to Obsidian task-list syntax.

## Current Behavior

The current Markdown converter preserves Apple Notes checklist state visually.

Apple Notes-style checklist HTML is represented as list items with `data-list-type="103"` and visible checkbox state in the list item text. The converter currently treats `data-list-type="103"` like an unordered list item and emits `-` followed by the original text.

This is why current output looks like:

```markdown
- ☑ Export locked notes cleanly
- ☐ Add task-list syntax later
```

The current behavior is intentional partial support. It preserves state, but it is not Obsidian-native task-list syntax.

## Target Behavior

For Obsidian Markdown export, Apple Notes checklist items should become native task-list items:

| Apple Notes state | Current output | Target Obsidian output |
|---|---|---|
| Checked | `- ☑ Done` | `- [x] Done` |
| Unchecked | `- ☐ Todo` | `- [ ] Todo` |

The conversion should apply only when the exporter has Apple Notes checklist metadata, not merely when arbitrary note text contains checkbox-looking characters.

## Scope

Implement conversion only for Markdown paths that are intended for Obsidian output.

In scope:

- `data-list-type="103"` checklist items.
- Checked markers represented by `☑`.
- Unchecked markers represented by `☐`.
- Existing indentation based on Apple Notes `data-indent`.
- Existing inline Markdown conversion for links, bold, italic, and other supported inline content.
- Existing nested list behavior where possible.

Out of scope for the first implementation:

- Changing HTML, PDF, RTF, TEX, or TXT export behavior.
- Inferring checklist state from arbitrary plain text without Apple Notes list metadata.
- Exporting Apple Notes checklist ordering, collapse state, or completion timestamps.
- Handling unknown future Apple Notes checklist markers without a test fixture.

## Conversion Rules

1. Detect checklist items by `data-list-type="103"`.
2. Convert only those checklist items to task-list markers.
3. Preserve indentation from `data-indent`.
4. Strip the leading Apple Notes checkbox marker from the item text.
5. Emit checked items as `- [x] <text>`.
6. Emit unchecked items as `- [ ] <text>`.
7. If a checklist item has metadata but no recognized leading checkbox marker, preserve the item as readable Markdown rather than guessing state.
8. Do not convert ordinary unordered list items that happen to start with `☑` or `☐` unless they also have Apple Notes checklist metadata.

## Example

Input HTML:

```html
<ul style='list-style-type: none;'>
  <li data-indent='0' data-list-type='103'>☑ Export locked notes cleanly</li>
  <li data-indent='1' data-list-type='103'>☐ Add task-list syntax later</li>
</ul>
```

Target Obsidian Markdown:

```markdown
- [x] Export locked notes cleanly
    - [ ] Add task-list syntax later
```

## Incremental Sync Consideration

This is a runtime export behavior change. Existing Apple Notes checklist notes may not have changed in Apple Notes, but their exported Markdown output would change.

Before implementation, decide how to force a safe one-time re-export for affected Markdown notes. Options include:

- version the Markdown export settings signature, if the sync manifest already tracks format-specific settings;
- version the checklist conversion path only for Markdown/Obsidian output;
- document that users should run a full export after enabling the behavior.

Avoid changing the canonical note content fingerprint for unrelated notes unless a migration path accepts the previous fingerprint. Prior fingerprint changes caused unnecessary full re-exports, so this needs to stay scoped.

## Required Tests Before Runtime Implementation

Add focused tests before changing output:

- Checked Apple Notes checklist item becomes `- [x]`.
- Unchecked Apple Notes checklist item becomes `- [ ]`.
- Indented checklist item preserves nesting.
- Normal unordered list item that starts with `☑` or `☐` does not convert without `data-list-type="103"`.
- Inline links and basic formatting inside checklist items survive conversion.
- Existing visual-state preservation test is updated or replaced deliberately.

## Release And Local Testing Plan

Because this changes exported Markdown, it should be treated as forward-facing runtime work.

When implemented:

1. Build and install a new local app build.
2. Bump the build number.
3. Re-add Full Disk Access if macOS requires it after app replacement.
4. Export a small checklist note and verify Obsidian renders interactive task checkboxes.
5. Run a second incremental sync and verify it does not re-export unrelated notes repeatedly.

Until implementation is approved and validated, the app should keep the current visible-checkbox behavior.
