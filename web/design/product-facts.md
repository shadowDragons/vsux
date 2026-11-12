# Product facts

Verified 2026-11-03 from repository README, Sources, Resources, and the running app.

- Product name: vsux. Earlier captures show the previous working title.
- Native macOS terminal built with SwiftUI / AppKit and Ghostty.
- Workspace list, split terminal tabs, file editing, Markdown preview, Git operations, per-workspace commands and background services.
- macOS 14+; Apple Silicon is verified by the local project.
- Workspace layouts persist; running processes and terminal scrollback do not survive restart.
- No bundled AI agent, cloud account, embedded browser, or third-party extension compatibility claim.
- Source: https://github.com/shadowDragons/vsux (verified against Git remote).
- The public `v0.1.2` prerelease provides an ad-hoc signed, not notarized Apple Silicon DMG for macOS 14+. The repository became public with the owner's authorization on 2026-11-12.
- Visual reference inspected live: a popular editor's product homepage. The page uses a centered title, platform CTA, and large product demonstration without borrowing third-party product copy or claims.

## Owner's positioning, 2026-10-28

The owner describes vsux as an AI-era editor with only the essential Git, text editing, syntax highlighting, file tree, terminal and multi-project tools. Open source enables users to add their own features with AI-assisted source changes. This is customization of source, not a claim of a plugin SDK or embedded AI integration. Comparisons of editor weight/terminal quality are motivation, not benchmark results, and are not published as measured claims.

## Screenshot provenance

The owner authorized public release on 2026-11-12, superseding the earlier prepare-only decision. The public history uses GitHub noreply addresses; the original history remains private. The article uses a new actual signed-out Public/Star 0 capture. Source customization refers to AI editing the repository, not built-in AI. Platform requirement: macOS 14+ and Apple Silicon only.

All eight current product images were captured from the actual native UI using a separate temporary app bundle (`local.vsux.marketing-demo`). It never restores workspace sessions; command storage is redirected to its own temporary directory. Code, project names, command labels and terminal output are newly authored fictional fixtures. Terminal transcripts are illustrative, not executed build/test output or product performance measurements. OCR checks found none of the known personal usernames, home paths, hostnames, or original project identifiers in the final images.

## Owner's origin story, 2026-10-29

After a year of vibe coding, parallel projects became routine. The owner found that running multiple editor windows and extensions felt heavy, and their integrated terminal did not fit their workflow. They liked a separate tool's project and workspace terminals, but wanted saved commands and fewer switches between editor and terminal. The landing page now presents this as first-person motivation, rather than a universal market claim. The result combines familiar file/editing/Git workflows with workspace terminals and project-specific commands. Shell scripts written with AI handle build/test/start commands. Markdown live preview and command copy/terminal insertion are verified in the current README and source. The ambiguous tool name “reg” is omitted. Product naming follows the existing vsux repository.

## Workspace services, 2026-11-02

Each workspace can configure local shell services with a name, command and optional working directory. Services run in the background without creating a terminal; the current workspace can start all stopped services, or start/stop/restart one service and inspect its recent bounded output. Switching workspaces leaves running processes alive; closing a workspace/window stops its services, and processes do not auto-restore after app restart. Screenshots use English fictional fixture data for all workspace, file, source, command, and terminal content, regardless of UI language. They show a fictional Orbit Studio `Docs preview` service rooted in its synthetic `docs/` fixture. It serves only local static files on loopback port 43281 and is stopped after capture.

## Ad-aligned copy, 2026-11-12

The user accepted the faster multi-project-focused ad and requested its copy and shots be applied to the article and landing page. Current copy positively acknowledges full editors for one project, frames memory/window/plugin pressure as the author's experience, and emphasizes project workspaces/terminals/commands/services. File/Git copy is brief. It avoids numerical memory claims, competitor names and an assertion that builds/checks are unnecessary. The subsequent authorized public launch adds the verified open-source invitation; source/download destinations are retained.

Illustrations come from the accepted Cinecode composition. They are not product screenshots or performance measurements. Native app evidence uses the already verified fictional fixture screenshots; the services/commands image only crops the actual sidebar.

## Project development method, 2026-11-12

The owner's final title is “花了 200 亿 Token，我做了一个多项目终端工作区 vsux，欢迎体验”, with an English equivalent. The 20-billion-token figure is owner-provided; no currency cost or percentage of AI-written code is claimed. Vibe Coding attribution was cancelled. The approved video narration stays intact; source customization, open-source status, platform limits and feedback invitation appear in the formal ending visuals.

## Current README imagery, 2026-11-12

Rebuilt the isolated demonstration app from source commit 9b74832 and recaptured Chinese/English workspace, editor, Markdown preview/outline and Git diff views. Eight actual captures, title-bar crop only, 2560px WebP quality 94, metadata stripped. Fictional Git history uses demo@example.invalid. OCR on all eight found no personal-home paths, usernames, credential patterns or private IPs. Services/commands sidebar is cropped with balanced insets; no controls are redrawn. README introduction now follows the open-source multi-project positioning and invites Star, AI-assisted source customization and Issues feedback.
