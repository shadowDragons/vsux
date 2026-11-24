# Releasing vsux

## Local DMG

Use Apple Silicon, macOS 14+, and Xcode 26 / Swift 6.2 or newer. Swift Markdown
0.7.3 requires Swift 6.2 even though this project's manifest uses tools 6.0.

```sh
Scripts/bootstrap-ghostty.sh
swift test
python3 Scripts/check-localizations.py
Scripts/release.sh 1.1.0
```

Outputs are `dist/vsux-1.1.0-macos-arm64.dmg` and the matching `.dmg.sha256`.
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
`shadowDragons/vsux` repository is public; v1.1.0 is the stable release target.

## GitHub Release

The workflow `.github/workflows/release.yml` builds on an Apple Silicon
`macos-26` runner and creates an unpublished release draft. Dependencies are
checked, security/core tests run, then the DMG, signed update feed, ZIP, available
delta patches and checksums are attached. Action
revisions are pinned and only the draft creation job has `contents: write`. CI
runs the full Swift test suite, website tests, the website production build
and npm audit.

1. Complete the license review, inspect screenshots/assets, and run the full
   test suite locally; CI also runs the full Swift test suite.
2. Commit the reviewed source in the clean repository and push it.
3. Tag that reviewed commit, e.g. `git tag v1.1.0`, and push the tag. Alternatively
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

## In-app updates and delta releases

Sparkle 2.9.6 handles update checks, download progress, Ed25519 verification,
installation and relaunch. The app menu and Settings include **Check for Updates**.
Automatic checks are opt-in (daily); unattended downloads/installations and
system profiling are disabled. Installation goes through the app's normal quit
handling, including unsaved-editor confirmation and workspace persistence.
Running shells, SSH sessions and services end on restart as on any normal quit.

The stable feed is a GitHub Release asset:
`https://github.com/shadowDragons/vsux/releases/latest/download/appcast.xml`.
Each enclosure uses an immutable `/releases/download/vX.Y.Z/` URL. Drafts and
prereleases do not become the stable feed. Always publish stable releases in
increasing version order and mark the newest stable release as latest. Keep an
`appcast.xml` asset in every subsequent stable release. Never edit a signed feed
after generation; regenerate and re-sign it instead.

### One-time signing setup

After `swift package resolve`, use the pinned tools shipped in
`.build/artifacts/sparkle/Sparkle/bin/`:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account vsux
```

This creates the private key in macOS Keychain and prints the **public** key.
Set the repository Actions **variable** `SPARKLE_PUBLIC_KEY` to that public key.
Export the private key with `generate_keys --account vsux -x /private/path/vsux.key`,
store its contents in the Actions **secret** `SPARKLE_PRIVATE_KEY`, then remove
the temporary export. Back up the key securely; all subsequent releases must
use the same key. Never commit it, place it in the app, or print it in CI logs.
The workflow passes the private key to Sparkle over stdin only during signing.
Both values must be configured before running the release workflow.

Sparkle signatures do not require an Apple Developer account and do not replace
Developer ID signing or notarization. The existing ad-hoc distribution caveat
still applies. A source build without `SPARKLE_PUBLIC_KEY` starts no updater;
its Check for Updates action explains how to upgrade that build.

### Local preparation

```sh
export SPARKLE_PUBLIC_KEY="$(.build/artifacts/sparkle/Sparkle/bin/generate_keys --account vsux -p)"
Scripts/release.sh 1.1.0
python3 Scripts/updates.py fetch-baseline 1.1.0 dist/update-baseline
python3 Scripts/updates.py package 1.1.0 --baseline dist/update-baseline
```

Fetching the previous release requires `gh` and network access. For offline
preparation, put previously published update ZIPs in the baseline directory,
or omit `--baseline` for a full update only. `UPDATE_REPOSITORY=owner/name`
configures forks consistently in both the build and packaging steps.

`dist/updates-1.1.0/` contains only uploadable assets: `appcast.xml`, the full
ZIP, useful delta patches and SHA-256 files. Upload all these files alongside
the DMG to the **same** release. The helper refuses to overwrite an existing
output directory. Review/move old output before regenerating it.

`CFBundleVersion` defaults to the marketing version (`1.1.0`), so local and CI
builds share one ordering. If overriding `BUILD_NUMBER`, keep it strictly
increasing across all distribution channels and never revert to smaller values.
The helper requires the feed to describe exactly the current build, include a
full fallback ZIP and valid signatures for every asset. Signing failures or a
public/private key mismatch stop publication preparation.

CI fetches the most recent older stable release's update ZIP and validates its
checksum. Sparkle generates a delta when it is worthwhile. Missing baselines,
skipped versions, or unavailable/inapplicable deltas use the full ZIP; a failed
delta download/application also falls back through Sparkle. The first release
with the updater has no prior update ZIP. **v1.0.0 users must manually install
a newer DMG once** before they can use in-app updates.

Validate real signing, delta generation/application and rejection of a tampered
archive with a disposable in-memory key (no production key required):

```sh
Scripts/build.sh release
VSUX_UPDATE_TEST_APP="$PWD/dist/vsux.app" python3 -m unittest discover -s Tests/Scripts -p test_updates.py
```

Before publishing, also test Check for Updates and installation between two
installed signed releases on a separate Mac. Offline signing/delta tests do not
exercise GitHub's published feed, Gatekeeper, permissions or the restart UI.
