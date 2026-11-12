import React from 'react';

export function SceneFigure({ src, alt, caption, label, onImage, actual = false, className = '', width, height }) {
  return <figure className={`story-figure ${actual ? 'actual-capture' : 'workflow-illustration'} ${className}`}>
    <button type="button" className="figure-enlarge" aria-label={label} onClick={() => onImage({ src, alt, caption, title: alt })}>
      <img src={src} alt={alt} loading="lazy" decoding="async" width={width || (actual ? 2560 : 1720)} height={height || (actual ? 1458 : 568)} />
      <span className="enlarge-mark" aria-hidden="true">↗</span>
    </button>
    <figcaption>{caption}</figcaption>
  </figure>;
}

export function shotSource(name, lang) {
  if (name === 'workspace') return `/assets/workspace-${lang}.webp`;
  return `/assets/story/${name}-${lang}.png`;
}
