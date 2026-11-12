# vsux

**Languages: [English](README.md) | [简体中文](README.zh-CN.md)**

A free, open-source lightweight editor for macOS. Built around the terminal, vsux keeps parallel projects in one window while you use your own AI coding tools. Keep split terminals, files, Git, saved commands, and background services together, organized by project.

Built with SwiftUI and AppKit, with terminal rendering and PTY support from Ghostty. MIT licensed. **macOS 14+ on Apple Silicon only.**

[![Latest release](https://img.shields.io/github/v/release/shadowDragons/vsux?include_prereleases&label=release)](https://github.com/shadowDragons/vsux/releases)
[![License](https://img.shields.io/github/license/shadowDragons/vsux)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-supported-555)

[Website](https://vsux.sphrag.com/) · [Download the macOS DMG](https://github.com/shadowDragons/vsux/releases/download/v0.1.2/vsux-0.1.2-macos-arm64.dmg) · [All releases](https://github.com/shadowDragons/vsux/releases) · [Report an issue](https://github.com/shadowDragons/vsux/issues)

> v0.1.2 is an Apple Silicon preview for macOS 14 or later. The app is ad-hoc signed and not notarized by Apple. Read [Installation](#installation) and [Security boundaries](#security-boundaries) before downloading.

If vsux fits your workflow, [give it a Star](https://github.com/shadowDragons/vsux). You can also use your AI coding tools to add features you need or remove ones you do not, then build your own version from source. Feedback and feature requests are welcome in [Issues](https://github.com/shadowDragons/vsux/issues).

## Why vsux

I increasingly work on several projects at once: AI edits a page in one, tests run in another, and a service stays running while I review the result. I wanted a single workspace for the tasks I still handle myself: terminals, files, diffs, commands, and services.

vsux has no built-in AI agent. Keep using the coding tools you already use in the terminal. It provides text editing and syntax highlighting; choose a full IDE when you need completion, navigation, or debugging.

Read the [illustrated product story](https://vsux.sphrag.com/?view=story).

## Contents

- [Features](#features)
- [Screenshots](#screenshots)
- [Installation](#installation)
- [Getting started](#getting-started)
- [Build from source](#build-from-source)
- [Data and privacy](#data-and-privacy)
- [Security boundaries](#security-boundaries)
- [Scope](#scope)
- [Contributing](#contributing)
- [License and acknowledgements](#license-and-acknowledgements)

## Features

- **Project workspaces:** Switch between local directories. Name, reorder, pin, or move workspaces to separate windows.
- **Terminals and splits:** Keep multiple terminal tabs in each workspace and split panes in four directions. Layouts, working directories, and appearance settings are saved locally.
- **Commands and services:** Save commands per workspace, run development services in the background, and inspect recent output.
- **Quick Tunnel:** Share a local HTTP port through a temporary Cloudflare URL. Requires a separately installed `cloudflared`; starting a tunnel asks for confirmation because anyone with the link can access the service.
- **File tools:** Browse, search, edit, and replace text within a workspace. Includes line numbers, syntax highlighting, and live Markdown preview.
- **Git:** Inspect repository status and diffs, stage and commit changes, switch branches, and use common remote, stash, tag, and worktree operations.
- **Native macOS experience:** Uses the system input methods, clipboard, mouse selection, and default shell. The interface is available in English and Simplified Chinese.

The app has no cloud account, sync, embedded browser, or AI agent. Git commands and configured background refreshes may contact the remotes set for your repositories.

## Screenshots

**Workspaces, split terminals, background services, and saved commands**

![vsux workspaces, split terminals, background services, and saved commands](web/public/assets/workspace-en.webp)

**File tree, syntax highlighting, and editing alongside project services**

![vsux file tree, code editor, and project services](web/public/assets/editor-en.webp)

**Markdown source and live preview with a document outline**

![vsux Markdown source, live preview, and document outline](web/public/assets/markdown-en.webp)

**Review a file diff before staging and committing**

![vsux Git changes, staging controls, and file diff](web/public/assets/git-en.webp)

Captured from the current native app on November 12, 2026. Orbit Studio is a fictional sample project; terminal output is illustrative demo data, not benchmark results.

## Installation

1. Download `vsux-0.1.2-macos-arm64.dmg` from the [v0.1.2 release](https://github.com/shadowDragons/vsux/releases/tag/v0.1.2).
2. Open the disk image and drag `vsux.app` to `Applications`.
3. Optionally download the `.dmg.sha256` file from the same release and verify the image:

   ```sh
   shasum -a 256 -c vsux-0.1.2-macos-arm64.dmg.sha256
   ```

This preview does not have an Apple Developer ID signature or notarization. If macOS blocks the app, first verify the download source and checksum, then follow the prompt in System Settings under Privacy & Security. Do not disable Gatekeeper globally.

## Getting started

1. Click the `+` in the left sidebar and choose a local project directory to create a workspace.
2. Click the middle `+` to add a terminal. Use the terminal toolbar's split menu to divide a pane.
3. Select the file or Git icon to open those tools. Press `⌘S` to save file edits.
4. Add frequently used commands in the right sidebar. **Fill Terminal** inserts a command into the terminal; review it and press Return yourself to run it.

Common shortcuts:

| Action | Shortcut |
| --- | --- |
| New window | `⌘N` |
| New terminal tab | `⌘T` |
| Split right | `⌘D` |
| Split down | `⌘⇧D` |
| Find in workspace files | `⌘⇧F` |
| Markdown side preview | `⇧⌘V` |

## Build from source

Requires macOS 14 or later, Apple Silicon, and Xcode 26 / Swift 6.2 or a newer toolchain. The first build downloads a pinned GhosttyKit build (about 123 MB) and SwiftPM dependencies. GhosttyKit is verified against a SHA-256 checksum before use.

```sh
git clone https://github.com/shadowDragons/vsux.git
cd vsux
./Scripts/build.sh
open dist/vsux.app
```

Run the tests and localization checks:

```sh
swift test
python3 Scripts/check-localizations.py
```

Local builds of `dist/vsux.app` are ad-hoc signed. To build a DMG and checksum, run `Scripts/release.sh 0.1.2`; the outputs are written to `dist/`. See the [release guide](docs/RELEASING.md) for the full process.

## Data and privacy

Workspaces, terminal layouts, editor tabs, and settings are stored locally. The app does not provide accounts or cloud sync. Git network access uses each repository's configured remotes and the local Git credential helper.

Workspace and command data are stored as local JSON in `~/Library/Application Support/vsux/`. The app's bundle identifier is `local.vsux.app`. These files have local filesystem permissions but are not encrypted. Relaunching restores workspace layouts and starts new shells; running processes, scrollback, and unsaved edits are not restored.

## Security boundaries

vsux runs shells, Git, and workspace services with the permissions of your macOS user. It is not a sandbox for untrusted projects. Shell startup files, Git hooks, credential helpers, and remote helpers may execute code; open only workspaces you trust. Exported command libraries may also contain sensitive text you entered, so review them before sharing.

Markdown preview renders raw HTML as text and blocks remote resources and local resources outside the workspace. See [SECURITY.md](SECURITY.md) for more details and vulnerability reporting instructions.

## Scope

The editor provides text editing and syntax highlighting, but not language servers, intelligent completion, or code navigation. Git covers common workflows; interactive rebase, cherry-pick, a dedicated merge-conflict editor, and submodule management are not currently included. Markdown preview does not currently support Mermaid or math. The project has no plugin SDK or embedded AI integration.

## Contributing

Use [GitHub Issues](https://github.com/shadowDragons/vsux/issues) to report bugs, suggest features, or discuss improvements. Pull requests are welcome. You can fork the MIT-licensed source and ask your own AI coding tool to help change it; review the changes and run the checks before using or sharing your build. Before submitting, run:

```sh
Scripts/bootstrap-ghostty.sh
swift test
python3 Scripts/check-localizations.py
```

For website changes, also run `npm ci`, `npm audit`, and `npm run build` from `web/`. Do not commit personal paths, credentials, signing keys, or real workspace data. Report security issues privately using the process in [SECURITY.md](SECURITY.md).

## License and acknowledgements

Original vsux code is licensed under the [MIT License](LICENSE). Third-party dependencies and their respective notices are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Terminal rendering and PTY support are provided by [Ghostty](https://github.com/ghostty-org/ghostty).

Project link: [github.com/shadowDragons/vsux](https://github.com/shadowDragons/vsux)
