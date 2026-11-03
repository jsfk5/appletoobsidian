# Output write boundary

Exports validate the selected output root and each destination before creating
directories, writing notes or attachments, rendering PDFs, saving the sync
manifest, or changing timestamps. Paths must remain inside the selected root.
Parent components (`..`) are rejected before path normalization. Incremental
sync stops before writing or pruning if a stored note or attachment path uses
one, even if the record is stale. Existing symbolic links at or below that root, including dangling links, are
rejected. Multiply linked regular files are also rejected to avoid changing an
external hard-link target. Normal filesystem aliases above the selected root
(such as the system temporary-directory alias) are resolved for comparison.

Attachment writes use atomic replacement. The checks do not change sync
fingerprints or request a library-wide re-export.

An unsafe directory aborts the export. An unsafe individual note or attachment
is reported through the existing failure summary. Manifest paths are checked
before export planning and again before saving. Cleanup retains its existing
resolved-path guards.

This is protection against existing redirected output paths, not a security
sandbox against another process actively replacing directories between a check
and an operation. Do not modify the output tree during export. Descriptor-based
filesystem operations would be needed for stronger race resistance.

Synthetic tests cover traversal, sibling-prefix confusion, internal/external
and dangling symlinks, linked roots, hard links, manifest targets, and full
exports through redirected folder/attachment paths. External sentinel bytes and
timestamps must remain unchanged. Existing incremental/no-op tests still apply.
Real-library candidate validation remains a separate pre-installation gate.
