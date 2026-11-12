import React, { useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import './styles.css';
import './story.css';
import { HeroAtmosphere, usePageEffects } from './effects';
import { copy, stories, repository, dmgRelease } from './content';
import { SceneFigure, shotSource } from './SceneFigure';
import { Story } from './Story';

function App() {
  const [lang, setLang] = useState(() => localStorage.getItem('vsux-web-language') === 'en' ? 'en' : 'zh');
  const [scene, setScene] = useState(0);
  const [comparison, setComparison] = useState(0);
  const [preview, setPreview] = useState(null);
  const isArticle = new URLSearchParams(location.search).get('view') === 'story';
  const dialog = useRef(null);
  const site = useRef(null);
  usePageEffects(site);
  const t = copy[lang];
  const imagePath = `/assets/${scene === 0 ? 'workspace' : 'editor'}-${lang}.webp`;
  useEffect(() => {
    document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
    document.title = `${isArticle ? stories[lang].title : t.title.join(' ')} · vsux`;
    const description = isArticle ? stories[lang].lead : t.description.replace('\n', ' ');
    document.querySelector('meta[property="og:title"]').content = document.title;
    document.querySelector('meta[property="og:description"]').content = description;
    document.querySelector('meta[name="description"]').content = description;
    localStorage.setItem('vsux-web-language', lang);
  }, [lang, t.description, isArticle]);
  function openImage(image) {
    setPreview(image);
    dialog.current.showModal();
  }

  return <div ref={site} className="site">
    <a className="skip-link" href="#main">{t.skip}</a>
    <header className="header wrap">
      <a href="/" className="brand" aria-label="vsux"><img src="/assets/vsux-logo.png" alt="" />vsux<span className="brand-slash">/</span></a>
      <nav aria-label={lang === 'zh' ? '主导航' : 'Main navigation'}>{t.nav.map((label, i) => <a key={i} href={['/#why-vsux', '/#features', '/?view=story'][i]}>{label}</a>)}</nav>
      <div className="header-actions"><button className="language" aria-label={t.langLabel} onClick={() => setLang(lang === 'zh' ? 'en' : 'zh')}>{t.lang}</button><a className="button button-small" href={dmgRelease}>{t.primary}<span aria-hidden="true">↓</span></a></div>
    </header>
    <main id="main">
      {isArticle ? <Story lang={lang} t={t} onImage={openImage} /> : <>
      <section className="hero wrap">
        <HeroAtmosphere />
        <div className="hero-copy">
          <p className="eyebrow"><span />{t.eyebrow}</p>
          <h1><span className="hero-line"><span>{t.title[0]}</span></span><span className="hero-line hero-line-accent"><span>{t.title[1]}</span></span></h1>
          <p className="hero-description">{t.description}</p>
          <div className="hero-actions"><a className="button" href={dmgRelease}><span aria-hidden="true">↓</span>{t.primary}</a><a className="button button-secondary" href={repository} target="_blank" rel="noreferrer">{t.secondary}<span aria-hidden="true">↗</span></a></div>
          <p className="platform">{t.platform}</p>
        </div>
        <figure className="product-stage" id="workflow">
          <div className="stage-meta"><span>vsux / workspace</span><span>JUST ENOUGH. ALL YOURS.</span></div>
          <div className="screenshot-scroll"><button className="screenshot-button" onClick={() => openImage({ src: imagePath, alt: t.imageAlt[scene], title: t.scenes[scene], caption: t.sample })} aria-label={t.zoom}><img className="product-image" src={imagePath} alt={t.imageAlt[scene]} fetchPriority="high" width="2560" height="1458" /></button></div>
          <div className="stage-controls"><div role="group" aria-label={t.gallery} className="scene-switch">{t.scenes.map((label, i) => <button key={i} aria-pressed={scene === i} onClick={() => setScene(i)}>{label}</button>)}</div><span className="image-hint">{t.imageHint}</span></div>
          <figcaption><span>{t.sample}</span><span className="mobile-hint">{t.mobileHint}</span></figcaption>
        </figure>
      </section>
      <section id="why-vsux" className="friction wrap" aria-labelledby="friction-title">
        <div className="friction-heading"><p className="eyebrow">WHY VSUX / 01</p><h2 id="friction-title">{t.frictionTitle}</h2><p className="section-intro">{t.frictionIntro}</p></div>
        <div className="narrative-step"><div className="narrative-copy"><h3>{t.parallelTitle}</h3><p>{t.parallelBody}</p></div><SceneFigure src={shotSource('parallel', lang)} alt={t.parallelAlt} caption={t.illustration} label={t.zoom} onImage={openImage} /></div>
        <div className="narrative-step"><div className="narrative-copy"><h3>{t.overheadTitle}</h3><p>{t.overheadBody}</p></div><SceneFigure src={shotSource('overhead', lang)} alt={t.overheadAlt} caption={t.illustration} label={t.zoom} onImage={openImage} /></div>
        <div className="role-change"><div><h3>{t.roleTitle}</h3><p>{t.roleBody}</p></div><ol>{t.roleTasks.map((task, i) => <li key={task}><span>0{i + 1}</span>{task}</li>)}</ol></div>
        <div className="comparison-scene"><div className="narrative-copy"><h3>{t.compareTitle}</h3><p>{t.compareBody}</p></div><div className="comparison-switch" role="group" aria-label={t.compareTitle}>{t.compareStates.map((label, i) => <button key={label} type="button" aria-pressed={comparison === i} onClick={() => setComparison(i)}>{label}</button>)}</div><SceneFigure src={shotSource(comparison ? 'essentials' : 'comparison', lang)} alt={t.compareAlt[comparison]} caption={t.illustration} label={t.zoom} onImage={openImage} /><p className="comparison-note">{t.compareNote}</p></div>
        <div className="resolution"><a className="brand" href="#features"><img src="/assets/vsux-logo.png" alt="" />vsux</a><h3>{t.resolutionTitle}</h3><p>{t.resolutionBody}</p><a href="/?view=story" className="text-link">{t.storyLink} ↗</a></div>
      </section>
      <section id="features" className="features wrap">
        <p className="eyebrow">EVERYDAY TOOLS / 02</p><h2>{t.features}</h2><p className="section-intro">{t.featureIntro}</p>
        <div className="feature-grid">{t.cards.map(([title, body], i) => <article key={title}><span className="feature-index">0{i + 1} /</span><h3>{title}</h3><p>{body}</p></article>)}</div>
        <article className="project-tools"><div><span className="feature-index">COMMANDS + SERVICES</span><h3>{t.toolsTitle}</h3><p>{t.toolsBody}</p></div><SceneFigure src={shotSource('project-tools', lang)} alt={t.toolsAlt} caption={t.sample} actual label={t.zoom} onImage={openImage} width={480} height={770} /></article>
        <article className="service-feature tunnel-feature" aria-labelledby="tunnel-title">
          <span className="feature-index">PORT FORWARDING /</span>
          <div>
            <h3 id="tunnel-title">{t.tunnelTitle}</h3>
            <p>{t.tunnelBody}</p>
            <figure className="tunnel-diagram">
              <div className="tunnel-route" role="img" aria-label={t.tunnelDiagramLabel} lang="en">
                <div><span className="tunnel-label">LOCAL HTTP SERVICE</span><code>localhost:3000</code></div>
                <span className="tunnel-arrow" aria-hidden="true">→</span>
                <div><span className="tunnel-label">PUBLIC PREVIEW</span><code>https://orbit-preview.example</code></div>
              </div>
              <figcaption>{t.tunnelCaption}</figcaption>
            </figure>
            <span className="extra-detail">{t.tunnelNote}</span>
          </div>
        </article>
      </section>
      <section id="philosophy" className="philosophy wrap">
        <div><p className="eyebrow">LESS, BY DESIGN.</p><h2>{t.philosophy}</h2><p className="section-intro">{t.philosophyIntro}</p></div>
        <div className="omitted"><h3 className="omitted-heading">{t.omittedTitle}</h3><ul>{t.omitted.map(([title, body], i) => <li key={i}><span className="omitted-cross" aria-hidden="true">×</span><div><h3>{title}</h3><p>{body}</p></div></li>)}</ul><p className="omitted-foot">{t.omittedFoot}</p></div>
      </section>
      <section id="open-source" className="fit-workflow wrap"><p className="eyebrow">YOUR AI. YOUR WORKFLOW.</p><h2>{t.fitTitle}</h2><p>{t.fitBody}</p><div><a href={repository} target="_blank" rel="noreferrer" className="text-link">{t.sourceLink} ↗</a><a href="/?view=story" className="text-link">{t.storyLink} ↗</a></div></section>
      <section id="start" className="start wrap"><div><p className="eyebrow">HELLO, VSUX.</p><h2>{t.start}</h2><p>{t.buildNote}</p><a href={`${repository}/${lang === 'en' ? 'blob/main/README.md#build-from-source' : 'blob/main/README.zh-CN.md#从源码构建'}`} target="_blank" rel="noreferrer" className="text-link">{t.build} ↗</a></div><pre><code>./Scripts/build.sh{'\n'}open "dist/vsux.app"</code></pre></section>
      </>}
    </main>
    <footer className="wrap"><a className="brand" href="/"><img src="/assets/vsux-logo.png" alt="" />vsux</a><span>{t.footer}</span><a href={repository} target="_blank" rel="noreferrer">GitHub ↗</a></footer>
    <dialog ref={dialog} className="image-dialog" aria-label={preview?.title || t.gallery} onClose={() => setPreview(null)} onClick={event => { if (event.target === dialog.current) dialog.current.close(); }}>
      <div className="dialog-toolbar"><span>{preview?.title}</span><button type="button" onClick={() => dialog.current.close()} aria-label={t.close}>×</button></div>
      {preview && <><img src={preview.src} alt={preview.alt} /><p>{preview.caption}</p></>}
    </dialog>
  </div>;
}
createRoot(document.getElementById('root')).render(<React.StrictMode><App /></React.StrictMode>);
