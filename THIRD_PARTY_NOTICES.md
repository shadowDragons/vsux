# Third-party components

The project's MIT license applies to original vsux code. Third-party components
retain their own licenses and notices; the project license does not relicense
them.

| Component | Version / source | License / notice |
| --- | --- | --- |
| GhosttyKit and C API | `manaflow-ai/ghostty`, commit `ef4f1570d62117ebc51e3b0f07ad4f34032267b6`; exact release and SHA-256 in `Scripts/bootstrap-ghostty.sh` | `Vendor/Ghostty-LICENSE` (MIT) |
| Swift Markdown | 0.7.3, `swiftlang/swift-markdown` | `Resources/Licenses/swift-markdown-LICENSE.txt` and NOTICE (Apache-2.0 with Swift Runtime Library Exception) |
| swift-cmark | Revision in `Package.resolved` | `Resources/Licenses/swift-cmark-COPYING.txt` |
| Highlight.js | 11.11.1 | `Resources/Licenses/highlightjs-LICENSE.txt` (BSD-3-Clause); asset checksums in `highlightjs-provenance.json` |
| VS Code Codicons, git-branch icon | Microsoft / VS Code Codicons; SVG converted to SwiftUI paths | `Resources/Licenses/vscode-codicons-LICENSE.txt` and NOTICE (CC BY 4.0) |
| React and React DOM (website) | 19.2.0 | MIT, distributed npm package licenses |
| Vite / React plugin (website build tools) | Locked in `web/package-lock.json` | MIT, distributed npm package licenses |

The app bundles its component licenses in `Contents/Resources/Licenses/`, plus
the Ghostty and project licenses. Research captures, decompilation output,
third-party product screenshots and extracted localization tables are excluded
from the clean source export.

The precompiled Ghostty archive is a supply-chain dependency. Its top-level MIT
notice is present; an exhaustive license inventory of libraries statically
linked into that upstream archive has not been completed in this review. Audit
that dependency closure before a general release. Upstream source is available
at <https://github.com/manaflow-ai/ghostty>.
