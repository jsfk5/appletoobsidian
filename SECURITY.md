# Security Policy

## Supported versions

This project is early in its public fork life. Security fixes are handled on the `main` branch until formal releases exist.

## Reporting a vulnerability

If you find a security issue, data-loss bug, path traversal bug, deletion-scope bug, or privacy issue, please avoid posting private note data in a public issue.

Open a GitHub issue with a minimal redacted report, or contact the maintainer through the GitHub profile if the report includes sensitive details.

Useful reports include:

- macOS version
- app version or commit hash
- whether you built from source or used a downloaded app
- the selected output folder shape, with private names redacted
- the exact action that triggered the issue
- redacted logs
- a synthetic reproduction case, if possible

## Sensitive information

Please do not send:

- Apple Notes databases
- full Obsidian vaults
- private exported notes
- credentials, keys, tokens, or passwords
- screenshots containing private note contents
- unredacted logs with personal file paths or note titles

## Data-loss and cleanup bugs

Sync mode may delete previously exported files inside the selected output folder when Apple Notes is treated as the source of truth. That behavior is intentional when the source note is deleted, moved to Recently Deleted, or moved out of the active export set.

It is a security-sensitive bug if cleanup escapes the selected output root, removes unrelated files, or removes files that should be protected by the current sync manifest.

## Safe testing

Before testing sync behavior:

- Back up your vault.
- Use a temporary output folder.
- Use synthetic notes when possible.
- Do not point experimental builds at irreplaceable note archives.

## Warranty

This project is distributed under the GNU General Public License v3.0 and is provided without warranty. See [LICENSE](LICENSE).
