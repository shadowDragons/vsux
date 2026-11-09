# vsux · Brand specification

Collected 2026-10-28. Identity comes from existing project assets.

- Logo: `/assets/vsux-logo.png`, copied without alteration from Resources/AppIcon.iconset/icon_512x512.png.
- Large logo: `/assets/vsux-logo-large.png`, original 1024 px asset.
- Logo works on light and dark backgrounds; preserve original colors and proportions.
- Accent: #59BAFF, sampled from the existing raster logo (the Swift generator uses calibrated blue).
- Background: #101214; surface: #191C1F; border: #2C3035; ink: #F3F4F5; muted: #9BA1A9. These are proposed marketing colors, not claims of existing brand guidelines.
- Display / body: DM Sans + Noto Sans SC; local sans-serif fallback.
- Character: local, focused, technical, restrained.
- Product images: `/assets/workspace-zh.webp`, `/assets/workspace-en.webp`, `/assets/editor-zh.webp`, `/assets/editor-en.webp`. Real native UI captured using isolated, synthetic Orbit Studio project data, including a fictional local Docs preview service. No existing user sessions were loaded. The title bar containing the system capture badge is cropped; UI content is otherwise unaltered. Each image is 2560 px wide, WebP quality 92; metadata is stripped.
- Image selection: workspace pair 9/10 for showing multi-project workflow, terminals and commands; editor pair 9/10 for showing real file tree, code editing and syntax highlighting. These first-party captures directly match the product; unrelated stock imagery is omitted.
- No invented statistics, testimonials, download numbers, performance metrics, or release versions.

## Approved design brief

Chinese / English landing page in web/, using a classic centered hero, centered title and actions above the real product image. The variant switcher and alternate layouts are removed from production code. Source-build CTA until a real release asset is supplied.

## Product positioning supplied by the owner

AI-era editor focused on six essentials: Git, text editing, syntax highlighting, a file tree, terminal, and multiple projects. Narrative: fewer editor windows, deliberate omission of full IDE features, open source customization using the developer's own AI coding tools. Do not imply a bundled AI agent, a plugin marketplace, or measured performance superiority.

## Motion direction

Owner requested more dramatic effects. Keep the real product capture as the focal point: blue particle links and a perspective grid suggest parallel workspaces, a staggered title introduces the page, and a narrow orbiting border frames the product. Pointer tilt stays within 2 degrees so screenshots remain readable. Lower sections reveal once on scroll; buttons use a single hover light sweep. Mobile uses static particles without tilt. Respect system reduced-motion preferences and suspend canvas work offscreen or in hidden tabs. All animated content is decorative and uses no workspace data.
