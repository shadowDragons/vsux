# Security

vsux is a local terminal and editor. It runs shells and Git as the logged-in
user; it is not a sandbox for untrusted projects. Use a separate OS account or
virtual machine when investigating untrusted repositories or executables.

## Trust boundaries

- Shell startup files, commands you run, Git hooks, signing programs, credential
  helpers, remote helpers and repository configuration can execute local code.
  Background fetch uses configured Git remotes and helpers. Only open trusted
  workspaces. A regular Git clone does not copy the source repository's local
  `.git/config` and hooks, but copied working trees may include them.
- Workspace services run commands saved by the user through the login Zsh shell
  with the user's environment and filesystem permissions. Their output stays in
  a bounded in-memory log. They are not sandboxed and are not automatically
  restarted after app relaunch; stop them before closing a workspace or window.
- Quick Tunnel starts a separately installed `cloudflared` only after an explicit
  public-access confirmation. It forwards a selected loopback HTTP port through
  Cloudflare; anyone with the temporary URL may access that service. Share only
  content intended for public access and stop the tunnel when finished. Tunnels
  do not restart automatically after app relaunch.
- Status refresh and file search disable Git filesystem monitors. Diff disables
  external diff drivers and text conversion programs. These restrictions do not
  make all other Git operations safe for untrusted local configuration.
- Saved commands and workspace metadata live under
  `~/Library/Application Support/vsux/` (older versions used `CmuxLocal/`). They are stored as local JSON,
  with private directory/file permissions; they are not encrypted. Exported
  command libraries may contain credentials you entered. Review before sharing.
- Markdown preview escapes raw HTML, blocks remote resources and limits local
  images to supported raster formats inside the workspace. External HTTP(S) and
  mail links open in the system handler when clicked.
- Editor file operations validate workspace boundaries and reject symlinks.
  This is not a defense against a malicious process running as the same user
  concurrently swapping filesystem entries.

## Downloads

Early DMG builds are Apple Silicon only, ad-hoc signed and not notarized by
Apple. Verify the repository and SHA-256 before installation. Checksums detect
corruption; a checksum hosted alongside a binary does not independently prove
publisher identity. Do not disable Gatekeeper globally.

## Reporting a vulnerability

Use the repository's **Security → Report a vulnerability** option if available.
If private reporting is not enabled, ask the maintainer for a private contact
without including exploit details, credentials, private files or terminal
transcripts in a public issue. Support currently targets the latest release.
