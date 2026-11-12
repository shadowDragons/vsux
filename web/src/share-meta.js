export const siteOrigin = 'https://web-delta-seven-29.vercel.app';

export const shareCopy = {
  zh: {
    title: 'vsux · 一款轻量编辑器',
    description: '一款以终端为核心的轻量编辑器。在一个窗口里同时推进多个项目，把文件、Git、命令和后台服务放在手边。免费开源，适用于 macOS 14+ 与 Apple Silicon。',
    alt: 'vsux：多个项目，一个工作区。免费开源的 macOS 轻量编辑器，配有中文实际界面。',
    locale: 'zh_CN',
  },
  en: {
    title: 'vsux · A lightweight editor',
    description: 'A lightweight editor built around the terminal. Keep parallel projects, files, Git, commands and background services in one window. Free and open source for macOS 14+ on Apple Silicon.',
    alt: 'vsux: More projects. One workspace. A free, open-source lightweight editor for macOS, with the actual English app interface.',
    locale: 'en_US',
  },
};

export function shareTags(lang) {
  const copy = shareCopy[lang];
  return [
    ['name', 'description', copy.description],
    ['property', 'og:title', copy.title],
    ['property', 'og:description', copy.description],
    ['property', 'og:type', 'website'],
    ['property', 'og:site_name', 'vsux'],
    ['property', 'og:url', `${siteOrigin}/${lang}/`],
    ['property', 'og:locale', copy.locale],
    ['property', 'og:locale:alternate', shareCopy[lang === 'zh' ? 'en' : 'zh'].locale],
    ['property', 'og:image', `${siteOrigin}/assets/og-${lang}.png`],
    ['property', 'og:image:type', 'image/png'],
    ['property', 'og:image:width', '1200'],
    ['property', 'og:image:height', '630'],
    ['property', 'og:image:alt', copy.alt],
    ['name', 'twitter:card', 'summary_large_image'],
    ['name', 'twitter:title', copy.title],
    ['name', 'twitter:description', copy.description],
    ['name', 'twitter:image', `${siteOrigin}/assets/og-${lang}.png`],
    ['name', 'twitter:image:alt', copy.alt],
  ];
}
