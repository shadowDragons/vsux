# Releasing vsux

## Local DMG

Use Apple Silicon, macOS 14+, and Xcode 26 / Swift 6.2 or newer. Swift Markdown
0.7.3 requires Swift 6.2 even though this project's manifest uses tools 6.0.

```sh
Scripts/bootstrap-ghostty.sh
swift test
python3 Scripts/check-localizations.py
Scripts/release.sh 0.1.2
```

Outputs are `dist/vsux-0.1.2-macos-arm64.dmg` and the matching `.dmg.sha256`.
The image contains vsux.app, an Applications shortcut and installation notes.
Builds start from an empty app staging directory and validate code signatures,
DMG integrity and executable architecture. No user preferences, workspace JSON,
local command libraries, `.git` directory or development logs are bundled.

These are ad-hoc signed previews. Developer ID signing, hardened runtime,
Apple notarization and stapling are not implemented by this workflow. For normal
public distribution, add and validate that process using an Apple Developer
account. Never commit signing keys or notarization credentials to the repo.

## Clean source repository

The current development repository contains research evidence and local paths
throughout its history. Keep it private. Do not fork it for publication, push
its existing branches/tags to the new repository, or assume deleting the files
in a new commit erases their history.

```sh
python3 Scripts/prepare-open-source.py
```

Review `dist/open-source/vsux/`, including the README and MIT license. The script
copies only named source/documentation paths and tracked website assets; it
excludes research, local notes, build products, dependencies, Git history and
Git configuration. It refuses to overwrite a prior export. It copies current
working files, including uncommitted fixes: review and commit the intended
release changes before tagging. Re-scan this export before uploading.

Create a fresh repository from this folder, with a single initial commit. Use a
GitHub noreply address if the current author email should remain private. Set
the public repository URL in `web/src/main.jsx`, `web/README.md` and
`web/design/product-facts.md` if its name differs from `shadowDragons/vsux`.
These instructions do not change repository visibility or create a remote.

Create the GitHub repository as **private** during preparation. Keep it private
until the owner changes its visibility. A Release draft remains unpublished;
publishing a draft and making the repository public are separate actions.

## GitHub Release

The workflow `.github/workflows/release.yml` builds on an Apple Silicon
`macos-26` runner and creates an unpublished prerelease draft. Dependencies are
checked, security/core tests run, then the DMG and checksum are attached. Action
revisions are pinned and only the draft creation job has `contents: write`. CI
runs the full Swift test suite, the website production build and npm audit.

1. Complete the license review, inspect screenshots/assets, and run the full
   test suite locally; CI also runs the full Swift test suite.
2. Commit the reviewed source in the clean repository and push it.
3. Tag that reviewed commit, e.g. `git tag v0.1.2`, and push the tag. Alternatively
   run the workflow manually against an existing `vX.Y.Z` tag.
4. Review the draft, download its assets, verify checksums, and test installation
   on a separate machine, including the oldest supported macOS version.
5. Publish the draft when ready. Update the website download URL and version in
   `web/src/main.jsx` and `web/design/product-facts.md` when cutting the next release.

The workflow intentionally fails if a release already exists; it does not
overwrite an existing release's assets. Review/delete the draft manually before
rerunning the same tag. An unsigned preview must be clearly labeled as such.

The website points directly to the published DMG, with source build instructions
kept as a secondary option.
