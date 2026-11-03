# Command-line startup

Command-line export starts from the application delegate's
`applicationDidFinishLaunching` callback, not a SwiftUI view's `onAppear`.
An unattended launch must not depend on a window becoming visible or active.

The delegate accepts CLI options once per process and retains an active-export
flag until the async operation returns. Closing the last window must not stop
an active CLI export. Normal GUI startup does not schedule a CLI export.
License acceptance, database errors, output selection and exit status still
use the existing export runner.

Before installing a build that changes startup:

- Run the full unit suite, including once-only startup without a window.
- Use a separately signed candidate and isolated export directory.
- Run repeated cold direct-executable exports with bounded timeouts and no UI
  activation or accessibility inspection during execution.
- Verify status, incremental/no-op results, per-note manifest records, output
  bytes and missing attachments. Keep the production app and scheduler unchanged.

Ad-hoc candidate rebuilds may require renewed Full Disk Access. A permission
failure is not evidence of a successful export or a launch hang.
