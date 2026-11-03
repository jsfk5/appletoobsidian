# Inventory read safety

Mirror sync must not interpret a failed database query as a deletion.

Account, folder and note inventory reads now return results only after SQLite
reports successful completion. A missing prepared statement, interrupted scan,
or failed result allocation returns an error rather than an empty or partial
inventory. Partial arrays are freed and their count is reset to zero.

A successful empty result remains distinct from failure. The Swift repository
throws on failed reads; both the GUI and command-line export entry points
already stop when the loading state contains an error. This change does not
alter note fingerprints, output filenames, renderer versions or sync settings.

Tests use synthetic databases for empty results, missing query columns,
interruption and retry. Existing export and incremental tests remain required.
Installation, Full Disk Access and real-library candidate validation are
separate gates from the unit tests.

This is not a transaction spanning all three inventory queries, nor proof
against every form of source corruption or schema drift. Write-side output
containment and folder/link invalidation are separate work items.
