// Static localized HTML is required: social crawlers generally do not run React.
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { shareCopy, shareTags, siteOrigin } from '../src/share-meta.js';

const escape = value => value.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
export function localizeHtml(source, lang) {
  const meta = shareTags(lang).map(([attr, name, value]) => `    <meta ${attr}="${name}" content="${escape(value)}" />`).join('\n');
  return source
    .replace(/<html lang="[^"]+">/, `<html lang="${lang === 'zh' ? 'zh-CN' : 'en'}">`)
    .replace(/\s*<meta (?:name="(?:description|twitter:[^"]+)"|property="og:[^"]+")[^>]*>/g, '')
    .replace(/\s*<link rel="(?:canonical|alternate)"[^>]*>/g, '')
    .replace(/<title>[^<]*<\/title>/, `<title>${escape(shareCopy[lang].title)}</title>`)
    .replace('</head>', `${meta}\n    <link rel="canonical" href="${siteOrigin}/${lang}/" />\n    <link rel="alternate" hreflang="zh-CN" href="${siteOrigin}/zh/" />\n    <link rel="alternate" hreflang="en" href="${siteOrigin}/en/" />\n  </head>`);
}

const source = await readFile(new URL('../dist/index.html', import.meta.url), 'utf8');
for (const lang of ['zh', 'en']) {
  const dir = new URL(`../dist/${lang}/`, import.meta.url);
  await mkdir(dir, { recursive: true });
  await writeFile(new URL('index.html', dir), localizeHtml(source, lang));
}
await writeFile(new URL('../dist/index.html', import.meta.url), localizeHtml(source, 'zh'));
