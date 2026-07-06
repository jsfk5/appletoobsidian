# Local Builds and Full Disk Access

Apple to Obsidian reads Apple Notes data from protected local macOS storage. A locally built app must have Full Disk Access before it can read the Notes database reliably.

This guide explains what to expect when building, replacing, and testing local app bundles.

## Why Permission Can Reset

macOS privacy permissions are tied to the exact app bundle macOS evaluates. The path, bundle identifier, executable, and code signature can all affect whether macOS treats a rebuilt app as the same app or a new one.

Local debug builds are commonly ad-hoc signed. Replacing an app in `/Applications` with a newly built ad-hoc bundle can cause macOS to require Full Disk Access again, even when the app name looks unchanged.

This is normal macOS behavior. It is not by itself an exporter bug.

## When You Need Full Disk Access

Full Disk Access is required when the app needs to read the local Apple Notes database.

Add the exact app bundle you run to:

```text
System Settings -> Privacy & Security -> Full Disk Access
```

If the app shows zero notes unexpectedly, reports a SQLite authorization error, or cannot find accounts that normally exist, verify Full Disk Access before debugging export logic.

## When To Rebuild Or Reinstall

You do not need to replace the installed app for every repository change.

Rebuild and reinstall the app when a change affects:

- runtime export behavior
- app metadata, build number, bundle identifier, signing, or entitlements
- command-line launch behavior
- Full Disk Access diagnostics
- local workflow validation

Do not replace the installed app for:

- docs-only commits
- test-only commits
- issue templates, README changes, or coverage matrix updates
- source comments that do not affect runtime behavior

Avoiding unnecessary replacements reduces Full Disk Access churn.

## Verifying The Installed Build

To verify the version and build number for an installed app:

```sh
defaults read "/Applications/Apple Notes Exporter.app/Contents/Info" CFBundleShortVersionString
defaults read "/Applications/Apple Notes Exporter.app/Contents/Info" CFBundleVersion
```

If you install a new runtime build, bump the build number first so testers can confirm they are running the intended bundle.

## Safer Local Replacement Flow

When a runtime change does require replacing the installed app:

1. Back up the target Obsidian vault or export into a temporary folder first.
2. Build the app.
3. Quit any running copy of the app.
4. Replace `/Applications/Apple Notes Exporter.app`.
5. Verify the installed build number.
6. Re-add Full Disk Access if macOS no longer trusts the replaced bundle.
7. Run one export against a temporary or known-safe output folder when practical.
8. Run a second incremental pass and confirm it settles to the expected note count.

For sync behavior changes, also verify that deleted notes, moved notes, and attachment folders are still scoped to the selected export root.

## Stable Signing

A stable signing identity may reduce permission churn compared with repeated ad-hoc signed replacement builds. It is still not a guarantee that macOS will preserve Full Disk Access after every replacement.

If you have a valid Apple Development or Developer ID signing identity, use the same bundle identifier, app path, signing identity, and team consistently across local replacement builds.

If you do not have a signing identity, ad-hoc signing is acceptable for local development. Expect to re-check Full Disk Access after replacing the app.

## Automation Notes

Scheduled exports should run the stable installed app bundle or a wrapper script that calls that bundle directly.

Avoid coordinate-based GUI automation for nightly exports. Window position, timing, focus, and permission prompts can make click automation unreliable.

The automation path should not point at a transient DerivedData build product unless you intentionally want to test that specific build.

## Public Release Note

Before a public binary release, this project still needs a dedicated release checklist covering the app rename, bundle identifier, signing identity, notarization, install instructions, and a fresh Full Disk Access test.
