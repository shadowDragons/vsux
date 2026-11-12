# Public release review

Reviewed November 12, 2026, before publishing `shadowDragons/vsux`.

## Scope and results

- Scanned all eight original commits and 163 unique Git blobs with Gitleaks
  8.30.1 and additional checks for credential assignments, private keys,
  authenticated URLs, personal home paths and private network addresses.
  No credential leakage was found in the intended public source or history.
- Reviewed intended working files separately. Generated film research and
  local build products remain excluded from the public repository.
- Identified personal commit-email metadata. With the owner's approval,
  replaced it with a GitHub noreply address, retaining all eight commits'
  file trees, messages, timestamps and parent relationships. Original history
  remains in a separate private repository. The old main commit URL returns
  404 to a signed-out visitor at the public project address.
- Ran OCR checks on 22 historical and new screenshot assets. No personal home
  paths, private network addresses, email addresses or common token prefixes
  were detected. Product examples use fictional demo data.
- Downloaded the v0.1.2 DMG and checksum from the prepared release. SHA-256,
  disk-image integrity and deep code-signature verification passed. Reviewed
  the 22 bundled files and executable strings; no personal home paths,
  credentials, user workspace settings or local command libraries were found.
  Release source is linked in the release notes.
- All 206 Swift tests passed, including existing security-behavior coverage.
  Localization checks passed for 588 bilingual messages and 749 source calls.
- npm audit reported zero known vulnerabilities.
- Enabled GitHub secret scanning, push protection and private vulnerability
  reporting on the public repository.

## Distribution limits

The v0.1.2 download is an Apple Silicon preview for macOS 14 or later. Its
signature is ad-hoc; it is not notarized by Apple. This review does not change
that status. Shells, Git helpers and configured services execute with the
current user's permissions, as documented in SECURITY.md.

These checks provide evidence for the reviewed source and artifacts. They are
not a penetration test or a guarantee that every security flaw is absent.
