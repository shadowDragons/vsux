# vsux landing page

Independent React + Vite web project. Run commands from this directory:

```sh
npm ci
npm run dev
```

The local development URL defaults to http://127.0.0.1:5173/.

```sh
npm run build
npm run preview
```

The static production output is in `dist/`.

## Page behavior

The production page uses the approved classic centered hero: centered title and actions, followed by a full-width product screenshot. Design variant controls and unused layouts have been removed. The header language button switches Chinese / English and remembers the selection locally. Page copy follows the owner's AI-era editor positioning and six essential tools.

The positioning section contrasts full-editor overhead and terminal-tool workflow gaps. It presents the owner's qualitative experience without performance metrics or claiming every terminal lacks these features. Three deliberately omitted IDE capabilities (integrated builds, intelligent completion, code/symbol navigation) use red crosses and strike-through text, with their CLI/AI alternatives explained. All copy is available in Chinese and English.

Port forwarding is presented alongside background services: enter a local HTTP port, create a temporary public link with Cloudflare Quick Tunnel, copy the address, and stop the tunnel when finished. The page notes the `cloudflared` prerequisite and public access. Its English-only diagram uses the reserved `.example` domain as a fictional, non-interactive illustration; it does not create a tunnel or expose any local service. Existing native screenshots remain unchanged.

The product gallery switches between native terminal/workspace and code-editor screenshots. Images change with the language, support click-to-enlarge and Escape to close, and scroll horizontally on small screens. Screenshot fixtures use English project names, files, code, service names, commands, and terminal output. The app UI switches Chinese / English while demo content stays English. All image content comes from newly authored, fictional Orbit Studio fixtures; existing personal workspaces and shell output are never used. The workspace capture includes a synthetic local Docs preview service served only from the fixture folder on loopback. The isolated app process and local service are stopped after captures. Logos are copied from the actual macOS app resources.

`scripts/make-demo-app.py` builds the isolated screenshot fixture in `/tmp/vsux-marketing-demo/` from copies of native sources and local Swift dependencies. It uses a distinct bundle identifier, disables session persistence and redirects its command library. It does not modify native product sources or the installed app. `VSUX_DEMO_LANGUAGE=en` selects English; `VSUX_DEMO_SCENE=editor` opens the sample code. Capture only the Orbit Studio window using CUA or manual screenshots. Final WebP images crop the top 56 px system title bar and retain the original UI, with no image metadata.

The download action points to the Apple Silicon DMG in the `v0.1.2` GitHub Release. Source-build instructions remain available in the project README.

`src/main.jsx` contains copy and layout; `src/styles.css` contains shared design tokens and responsive styles. Google Fonts supplies DM Sans and Noto Sans SC, with local sans-serif fallback. `design/` records facts and design assumptions.

`src/effects.jsx` and `src/effects.css` add a staggered hero entrance, blue particle connections, a perspective grid, traveling signals, an orbiting screenshot border, pointer-driven product tilt, scroll reveals and a terminal cursor. The canvas stops animating when offscreen or the tab is hidden. Small screens use a static particle field and disable tilt; the system's reduced-motion preference disables entrances, tilt and looping CSS motion while keeping all content visible. Effects use native browser APIs with no extra animation dependency.

## Verified

- Production build succeeds; dependency audit has no known vulnerabilities.
- Playwright verifies both languages, both screenshot scenes, mobile/tablet/desktop layouts, language persistence, screenshot zoom and Escape, and source-build navigation.
- No runtime page errors or horizontal document overflow in those checks.
- The selected layout is checked at mobile/tablet/desktop widths, including language persistence, both gallery scenes, screenshot zoom, navigation, pointer tilt/reset and system reduced-motion behavior.
- Screenshots are stored locally in the ignored `design/screenshots/` directory for review.
- Product assets in `public/assets/` have been visually inspected and checked with local OCR for personal usernames, paths, hostnames and the original project name.
