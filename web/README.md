# vsux landing page and illustrated story

Independent React + Vite project, with Chinese and English copy.

```sh
npm ci
npm run dev
npm run build
```

Vite prints the local URL (normally `http://127.0.0.1:5173/`). Build output is `dist/`.

- `/` is the product landing page.
- `/?view=story` is the illustrated origin article. A query parameter keeps direct navigation compatible with static hosting, without a client router or rewrite rules.
- The language button switches all copy, diagram labels and native screenshots, and remembers the choice locally.

## Narrative and imagery

The page and article follow the approved product ad: a complete editor is useful for one project; AI enables several projects at once; repeated environments, language services and extensions burden the author's workflow; vsux focuses on project workspaces, terminals and everyday handoffs. This is a first-person motivation, with no memory benchmark, savings figure, competitor comparison or built-in AI claim. File/Git coverage is concise; project commands and services stay prominent. Build and check scripts still run in the terminal.

`src/content.js` contains the bilingual landing copy and full article. `src/main.jsx`, `src/Story.jsx` and `src/SceneFigure.jsx` render them; shared native styles and article/narrative styles live in `styles.css` and `story.css`.

`public/assets/story/` contains four approved ad scenes in both languages and two native sidebar crops. `provenance.json` records the scene timestamps, source and crops. Diagrams are explicitly labelled illustrations; native UI captures are separately labelled. The comparison can switch between the original full setup and the state after unused editor modules have been removed. Figures open in a shared image dialog, close on Escape or backdrop click, and have localized alt text.

`python3 scripts/export-ad-frames.py` regenerates these assets when the local approved Cinecode composition exists at `../广告/vsux-30s/film.html`. It uses that project's still-render tools. English versions preserve the scene geometry/state and translate visible labels, with a small type-size adjustment for fit. It never changes the approved film. All exported image assets are checked into this web project; the local film project is not required to build or serve the site.

Native screenshots (`workspace-{zh,en}.webp`, `editor-{zh,en}.webp`) are actual app captures with fictional Orbit Studio fixtures. The native sidebar image is only cropped, with no UI alteration. `scripts/make-demo-app.py` builds the isolated screenshot fixture; it does not load personal sessions or modify native product sources. The logo comes from the app's resources.

Downloads retain the existing `v0.1.2` Apple Silicon DMG URL. The source-build links target the appropriate language README.

## Motion and verification

The existing hero particles, perspective grid, pointer tilt, screenshot border, entrances and scroll reveals are retained. Reduced-motion preferences disable motion while preserving content. Article pages support the same effects hook without requiring a hero screenshot.

Verified after the narrative/image update:

- `npm ci` completed with zero known dependency vulnerabilities; production build succeeds.
- Chinese and English landing/article views were checked at 390, 768 and 1440 px widths: no runtime errors, broken visible images or horizontal document overflow.
- Both gallery scenes, before/after comparison images, image dialogs and Escape were exercised; language selection persists when opening the article.
- Desktop and mobile screenshots, comparison diagrams, article typography and the native sidebar crop were visually inspected.

Local verification outputs are ignored under `design/screenshots/`.

## Open-source launch

The repository is public at `https://github.com/shadowDragons/vsux`. The article includes the launch invitation: MIT/open source, Stars, AI-assisted source customization, macOS 14+ on Apple Silicon, and Issues feedback. `github-public.jpg` is an actual signed-out public-repository capture from November 12, 2026; provenance records its crop. The v0.1.2 DMG and checksum are published as an Apple Silicon prerelease. The app remains ad-hoc signed and not notarized.

The release section was checked in both languages at 390 and 1440 px, including the GitHub image dialog and exact repository/Issues links. No runtime errors, failed images or horizontal overflow were found.
