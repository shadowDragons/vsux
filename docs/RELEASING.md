# Releasing vsux

## Local DMG

Use Apple Silicon, macOS 14+, and Xcode 26 / Swift 6.2 or newer. Swift Markdown
0.7.3 requires Swift 6.2 even though this project's manifest uses tools 6.0.

```sh
Scripts/bootstrap-ghostty.sh
swift test
python3 Scripts/check-localizations.py
Scripts/release.sh 1.0.0
```

Outputs are `dist/vsux-1.0.0-macos-arm64.dmg` and the matching `.dmg.sha256`.
The image contains vsux.app, an Applications shortcut and installation notes.
Builds start from an empty app staging directory and validate code signatures,
DMG integrity and executable architecture. No user preferences, workspace JSON,
local command libraries, `.git` directory or development logs are bundled.
The assembled executable also checks its installed English catalog and syntax
highlighting resources before any user-data migration or UI startup, using
`--verify-bundled-resources`. This catches packaging differences between the
native SwiftPM and Xcode build drivers.

These builds are ad-hoc signed and not notarized. Developer ID signing,
hardened runtime, Apple notarization and stapling are not implemented by this
workflow. For normal
public distribution, add and validate that process using an Apple Developer
account. Never commit signing keys or notarization credentials to the repo.

## Clean source repository

The public repository contains reviewed source and an anonymized commit
history. Private research, local notes, credentials, build products and user
workspace data must stay out of it. Review every branch, tag and asset before
publication; deleting a file in a new commit does not erase older versions.

```sh
python3 Scripts/prepare-open-source.py
```

Review `dist/open-source/vsux/`, including the README and MIT license. The script
copies only named source/documentation paths and Git-tracked files under
Sources, Tests, Resources and web. Untracked files are excluded; add intended
new source files to Git only after reviewing them. Credential configuration
files and directories are rejected even if tracked, except the reviewed
`web/.env.example` template containing public placeholders and empty secrets. Build products,
dependencies, Git history and local Git configuration are excluded.
It refuses to overwrite a prior export. It copies current working versions of
eligible files, including uncommitted fixes: review and commit the intended
release changes before tagging. Re-scan this export before uploading; tracked
files can still contain private information.

Run the export boundary regression tests with:

```sh
python3 -m unittest discover -s Tests/Scripts -p 'test_*.py'
```

For a separate source export, create a fresh repository from that folder. Use a
GitHub noreply address for author and committer metadata. Project and download
links are maintained in `web/src/content.js`; update them if the destination
changes. The export script does not create a remote or change visibility.

Prepare new repositories privately until the owner authorizes publication.
A Release draft remains unpublished until explicitly released. The current
`shadowDragons/vsux` repository is public; v1.0.0 is the stable release target.

## GitHub Release

The workflow `.github/workflows/release.yml` builds on an Apple Silicon
`macos-26` runner and creates an unpublished release draft. Dependencies are
checked, security/core tests run, then the DMG and checksum are attached. Action
revisions are pinned and only the draft creation job has `contents: write`. CI
runs the full Swift test suite, website tests, the website production build
and npm audit.

1. Complete the license review, inspect screenshots/assets, and run the full
   test suite locally; CI also runs the full Swift test suite.
2. Commit the reviewed source in the clean repository and push it.
3. Tag that reviewed commit, e.g. `git tag v1.0.0`, and push the tag. Alternatively
   run the workflow manually against an existing `vX.Y.Z` tag.
4. Review the draft, download its assets, verify checksums, and test installation
   on a separate machine, including the oldest supported macOS version.
5. Publish the draft when ready. Update the website download URL and version in
   `web/src/content.js` and `web/design/product-facts.md` when cutting the next release.

The workflow intentionally fails if a release already exists; it does not
overwrite an existing release's assets. Review/delete the draft manually before
rerunning the same tag. Ad-hoc signing and the absence of Apple notarization
must be clearly disclosed.

The website points directly to the published DMG, with source build instructions
kept as a secondary option.
