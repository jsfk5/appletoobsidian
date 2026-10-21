# Duplicate-title repair

The export planner reserves manifest-owned filenames before assigning new paths.
Notes whose titles differ only by case or canonically equivalent Unicode spelling
receive separate paths. Attachment folders follow each note's assigned basename.

If an existing manifest assigns one path to multiple note IDs, the exporter
re-exports those notes to separate destinations. For Markdown, it refreshes the
entire selected export set once so links from other notes follow the repaired
destinations. The export log explicitly reports this repair. Ordinary incremental
sync does not refresh the entire set when no collision or pending repair exists.

Old shared files and attachments are preserved during individual repairs. Final
cleanup uses the resulting manifest, including entries for failed notes. A pending
link-refresh marker survives failed repairs so a later successful export can
finish the repair. Successful completion clears that marker, allowing subsequent
unchanged exports to return to a no-op.

Synthetic tests cover planning, case/Unicode aliases, attachment isolation,
renames/moves, deletion, full Markdown repair, cross-note links, a partial write
failure, retry, and a subsequent no-op. These tests do not replace candidate
validation against an isolated copy of an existing export before installation.
