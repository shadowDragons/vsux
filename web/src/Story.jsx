import React from 'react';
import { stories, repository } from './content';
import { SceneFigure, shotSource } from './SceneFigure';

export function Story({ lang, t, onImage }) {
  const story = stories[lang];
  const alts = { parallel: t.parallelAlt, overhead: t.overheadAlt, comparison: t.compareAlt[0], workspace: t.imageAlt[0], 'project-tools': t.toolsAlt };
  return <article className="story-page wrap" aria-labelledby="story-title">
    <header className="story-heading">
      <a className="text-link" href="/">← {t.back}</a>
      <p className="eyebrow">{t.storyLabel}</p>
      <h1 id="story-title">{story.title}</h1>
      <p className="story-lead">{story.lead}</p>
    </header>
    {story.sections.map((section, index) => <section className="story-section" key={section.title}>
      <div className="story-prose"><span className="story-number" aria-hidden="true">0{index + 1}</span><h2>{section.title}</h2>{section.paragraphs.map(text => <p key={text}>{text}</p>)}</div>
      {section.image && <SceneFigure src={shotSource(section.image, lang)} alt={alts[section.image]} caption={section.actual ? t.sample : t.illustration} actual={section.actual} label={t.zoom} onImage={onImage} className={section.image === 'project-tools' ? 'story-tools-image' : ''} width={section.image === 'project-tools' ? 480 : undefined} height={section.image === 'project-tools' ? 770 : undefined} />}
    </section>)}
    <section className="story-section release-section" aria-labelledby="release-title">
      <div className="story-prose"><h2 id="release-title">{story.release.title}</h2>{story.release.paragraphs.map(text => <p key={text}>{text}</p>)}</div>
      <SceneFigure src="/assets/story/github-public.jpg" alt={story.release.imageAlt} caption={story.release.caption} label={t.zoom} onImage={onImage} actual width={1220} height={850} />
      <div className="release-links story-prose">
        <p>{story.release.project}<a href={repository} target="_blank" rel="noreferrer">{repository}</a></p>
        <p>{story.release.issues}<a href={`${repository}/issues`} target="_blank" rel="noreferrer">{repository}/issues</a></p>
        <div><a className="button" href={repository} target="_blank" rel="noreferrer">☆ {story.release.star}</a><a className="text-link" href={`${repository}/issues`} target="_blank" rel="noreferrer">{story.release.feedback} ↗</a></div>
      </div>
    </section>
    <div className="story-end"><a className="text-link" href="/">← {t.back}</a><a href={repository} className="text-link" target="_blank" rel="noreferrer">{t.sourceLink} ↗</a></div>
  </article>;
}
