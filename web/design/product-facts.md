# Product facts

Verified 2026-11-03 from repository README, Sources, Resources, and the running app.

- Product name: vsux. Earlier captures show the previous working title.
- Native macOS terminal built with SwiftUI / AppKit and Ghostty.
- Workspace list, split terminal tabs, file editing, Markdown preview, Git operations, per-workspace commands and background services.
- macOS 14+; Apple Silicon is verified by the local project.
- Workspace layouts persist; running processes and terminal scrollback do not survive restart.
- No bundled AI agent, cloud account, embedded browser, or third-party extension compatibility claim.
- Source: https://github.com/shadowDragons/vsux (verified against Git remote).
- The prepared `v0.1.2` Release draft targets an ad-hoc signed, not notarized Apple Silicon DMG for macOS 14+. The repository stays private until the owner makes it public.
- Visual reference inspected live: a popular editor's product homepage. The page uses a centered title, platform CTA, and large product demonstration without borrowing third-party product copy or claims.

## Owner's positioning, 2026-10-28

The owner describes vsux as an AI-era editor with only the essential Git, text editing, syntax highlighting, file tree, terminal and multi-project tools. Open source enables users to add their own features with AI-assisted source changes. This is customization of source, not a claim of a plugin SDK or embedded AI integration. Comparisons of editor weight/terminal quality are motivation, not benchmark results, and are not published as measured claims.

## Screenshot provenance

All four product images were captured from the actual native UI using a separate temporary app bundle (`local.vsux.marketing-demo`). It never restores workspace sessions; command storage is redirected to its own temporary directory. Code, project names, command labels and terminal output are newly authored fictional fixtures. Terminal transcripts are illustrative, not executed build/test output or product performance measurements. OCR checks found none of the known personal usernames, home paths, hostnames, or original project identifiers in the final images.

## Owner's origin story, 2026-10-29

After a year of vibe coding, parallel projects became routine. The owner found that running multiple editor windows and extensions felt heavy, and their integrated terminal did not fit their workflow. They liked a separate tool's project and workspace terminals, but wanted saved commands and fewer switches between editor and terminal. The landing page now presents this as first-person motivation, rather than a universal market claim. The result combines familiar file/editing/Git workflows with workspace terminals and project-specific commands. Shell scripts written with AI handle build/test/start commands. Markdown live preview and command copy/terminal insertion are verified in the current README and source. The ambiguous tool name “reg” is omitted. Product naming follows the existing vsux repository.

## Workspace services, 2026-11-02

Each workspace can configure local shell services with a name, command and optional working directory. Services run in the background without creating a terminal; the current workspace can start all stopped services, or start/stop/restart one service and inspect its recent bounded output. Switching workspaces leaves running processes alive; closing a workspace/window stops its services, and processes do not auto-restore after app restart. Screenshots use English fictional fixture data for all workspace, file, source, command, and terminal content, regardless of UI language. They show a fictional Orbit Studio `Docs preview` service rooted in its synthetic `docs/` fixture. It serves only local static files on loopback port 43281 and is stopped after capture.
