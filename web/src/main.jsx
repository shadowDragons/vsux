import React, { useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import './styles.css';
import { HeroAtmosphere, usePageEffects } from './effects';

const repository = 'https://github.com/shadowDragons/vsux';
const dmgRelease = `${repository}/releases/download/v0.1.2/vsux-0.1.2-macos-arm64.dmg`;
const copy = {
  zh: {
    nav: ['功能', '设计取舍', '开源'], lang: 'EN', langLabel: 'Switch to English', skip: '跳至主要内容',
    eyebrow: '为 macOS 而生 · AI 时代的轻量编辑器', title: ['AI 时代，', '编辑器只需刚好。'],
    description: '极简、轻量，为多项目并行而生。\nGit、编辑、终端、项目服务与端口转发，都在一个工作区。',
    primary: '下载 DMG', secondary: '查看源代码', platform: 'macOS 14+ · Apple Silicon · Ghostty 终端内核',
    scenes: ['多项目与分屏终端', '目录树与代码编辑'], gallery: '产品界面', zoom: '放大查看截图', close: '关闭截图',
    imageAlt: ['vsux 演示：Orbit Studio 等多个工作区、分屏终端、后台服务与常用命令', 'vsux 演示：Orbit Studio 文件树、TypeScript 语法高亮与文本编辑'],
    sample: '应用实拍 · 全部为虚构演示数据', imageHint: '点击放大，查看界面细节', mobileHint: '左右滑动查看完整界面 · 点击放大',
    features: '日常开发，一个工作区就够了。', featureIntro: '六项日常能力，再加上项目服务与端口转发。',
    cards: [
      ['Git', '看 Diff、暂存、提交、切换分支。代码的变化，就在手边。'],
      ['文本编辑', '打开即改，⌘S 保存。改代码、调配置、预览 Markdown，不必再开一个编辑器。'],
      ['语法高亮', '代码有层次，阅读更清楚。保留看懂代码所需的基本能力。'],
      ['目录树', '按项目浏览目录与文件，快速找到 AI 刚刚改过的地方。'],
      ['终端', 'Ghostty 驱动的原生终端。Tab、分屏、常用命令，贴合命令行工作流。'],
      ['多项目', '一个窗口容纳多个工作区，各自保留布局、文件标签与常用命令。'],
    ],
    serviceTitle: '项目服务，也在工作区里。', serviceBody: '需要常驻的开发服务，不用占一个终端 Tab。按工作区保存服务命令，一键启动；也可单独停止、重启或查看日志。', serviceNote: '后台运行 · 工作区独立配置 · 输出随时可查',
    tunnelTitle: '本地跑起来，发个链接就能看。',
    tunnelBody: '输入本地 HTTP 服务的端口，通过 Cloudflare Quick Tunnel 生成临时公网链接。给同事看页面、用手机验效果，复制地址即可分享；用完随时停止。',
    tunnelNote: '按工作区管理 · 需安装 cloudflared · 拿到链接即可访问，请只分享可公开的内容。',
    tunnelCaption: '转发流程示意 · 英文虚构数据，非真实访问地址',
    tunnelDiagramLabel: '端口转发示意：本地端口 3000 通过公网链接分享',
    frictionTitle: '喜欢的留下，负担放下。', frictionIntro: 'Vibe coding 一年后，我想把编辑器和终端的长处，放进一个轻量工作区。',
    frictionCards: [
      ['功能完整的编辑器', '文件树 · 编辑 · Git · Markdown', '同时打开多个项目、安装不少扩展后，用起来开始变重。精简扩展后，内置终端仍不合我的习惯。'],
      ['终端优先的工具', '多项目 · 多工作区 · 分屏终端', '终端工作流很顺手，但改文件、看 Git 还得切换工具，常用命令也需要一个归处。'],
    ],
    resolutionTitle: '合在一起，刚好够用。', resolutionBody: '编辑、Git、多工作区终端，再加上常用命令、后台服务和端口转发。从开发到分享，都在项目里完成。',
    extras: [
      ['常用命令，跟着项目走。', '启动、测试、构建脚本，按工作区保存。一键复制或填入终端，确认后按回车执行。不必记住每个项目的命令。', '命令按工作区独立保存'],
      ['Markdown，边写边看。', 'AI 写的方案、项目说明和开发笔记，在编辑器里直接预览，减少一次工具切换。', '编辑与实时预览并排显示'],
    ],
    philosophy: '轻量，\n从少做一点开始。', philosophyIntro: '在 AI 驱动的工作流里，我们选择聚焦六项基础能力。完整 IDE 的这些功能，按需舍弃。',
    omittedTitle: '这些功能，不必内置。',
    omitted: [
      ['内置编译与构建系统', '让 AI 写好 Shell 脚本，在终端里构建、测试、运行。'],
      ['代码智能补全', '代码生成交给你习惯的 AI 编程工具。'],
      ['代码跳转与符号导航', '日常查看与修改，先用目录树、搜索和文本编辑完成。'],
    ],
    omittedFoot: '需要更多？开源代码在你手里，交给 AI 按需加回来。',
    buildThought: '要编译、要运行。\n一个 Shell 脚本就够了。', buildThoughtBody: '让 AI 写脚本，把启动命令存下来。为了运行项目，不必再带上一整套 IDE。',
    openTitle: '要什么功能，\n让 AI 帮你加。', openDescription: '开源，让工具留在你手里。把源码交给你习惯的 AI 编程工具，添加自己的功能，改成自己的工作方式。',
    openLink: '打开源码，开始定制', promptLabel: '从一个你自己的需求开始', prompt: '给常用命令加一个按标签筛选的入口，\n支持我自己的分类方式。', promptFoot: '你的需求 → AI 修改源码 → 你的 vsux',
    start: '下一个项目，轻装开始。', build: '从源码构建', buildNote: 'macOS 14+ · 仅支持 Apple Silicon。',
    footer: '恰好够用，自由生长。',
  },
  en: {
    nav: ['Features', 'Philosophy', 'Open source'], lang: '中文', langLabel: '切换为中文', skip: 'Skip to content',
    eyebrow: 'MADE FOR macOS · A LIGHTER EDITOR FOR THE AI ERA', title: ['The AI era.', 'Just enough editor.'],
    description: 'Minimal. Lightweight. Made for parallel projects.\nGit, editing, terminals, local services, and port forwarding in one workspace.',
    primary: 'Download DMG', secondary: 'View source', platform: 'macOS 14+ · Apple Silicon · Powered by Ghostty',
    scenes: ['Projects & split terminals', 'File tree & code editing'], gallery: 'Product screenshots', zoom: 'Enlarge screenshot', close: 'Close screenshot',
    imageAlt: ['vsux demo: Orbit Studio workspaces, split terminals, background services, and saved commands', 'vsux demo: Orbit Studio file tree, TypeScript syntax highlighting, and text editing'],
    sample: 'Captured in the app · All data is fictional', imageHint: 'Click to explore the details', mobileHint: 'Swipe to see the full workspace · Tap to enlarge',
    features: 'One workspace for everyday development.', featureIntro: 'Six essentials, plus project services and port forwarding.',
    cards: [
      ['Git', 'Review diffs, stage changes, commit, and switch branches. Stay close to your code.'],
      ['Text editing', 'Open, edit, and save. Change code, adjust config, and preview Markdown without opening another editor.'],
      ['Syntax highlighting', 'Readable code at a glance. Keep the essentials for understanding what changed.'],
      ['File tree', 'Browse each project’s files and find the changes your AI just made.'],
      ['Terminal', 'A native terminal powered by Ghostty. Tabs, splits, and saved commands for your CLI workflow.'],
      ['Multiple projects', 'Keep projects in one window, each with its own layout, file tabs, and saved commands.'],
    ],
    serviceTitle: 'Project services belong in the workspace.', serviceBody: 'Keep long-running processes out of your terminal tabs. Save service commands per workspace, start them together, or stop, restart, and inspect logs individually.', serviceNote: 'Runs in the background · Configured per workspace · Logs on demand',
    tunnelTitle: 'Run it locally. Share it with a link.',
    tunnelBody: 'Enter your local HTTP service’s port to create a temporary public link with Cloudflare Quick Tunnel. Share a preview with a teammate or check it on your phone. Copy the address, then stop the tunnel when you’re done.',
    tunnelNote: 'Managed per workspace · Requires cloudflared · Anyone with the link can access it. Share only content you intend to make public.',
    tunnelCaption: 'Illustrative flow · Fictional English data, not a live address',
    tunnelDiagramLabel: 'Port forwarding illustration: share local port 3000 through a public link',
    frictionTitle: 'Keep the good. Lose the weight.', frictionIntro: 'After a year of vibe coding, I wanted the best of my editor and terminal in one lightweight workspace.',
    frictionCards: [
      ['Full-featured editors', 'Files · Editing · Git · Markdown', 'With several projects and extensions open, my editor began to feel heavy. Even after trimming extensions, its integrated terminal did not fit my workflow.'],
      ['Terminal-first tools', 'Projects · Workspaces · Split terminals', 'The terminal workflow felt right, but editing files and reviewing Git meant switching tools. Recurring commands needed a home, too.'],
    ],
    resolutionTitle: 'Together. Just enough.', resolutionBody: 'Editing, Git, workspace terminals, saved commands, local services, and port forwarding. Develop and share from the same workspace.',
    extras: [
      ['Your commands. With your project.', 'Save startup, test, and build commands per workspace. Copy one or insert it into the terminal, then press Enter when ready. No need to memorize every project’s scripts.', 'Commands saved independently per workspace'],
      ['Markdown. Edit and preview.', 'Read AI-generated plans, project documentation, and development notes right in the editor. One less reason to switch tools.', 'Editing and live preview, side by side'],
    ],
    philosophy: 'Lightweight starts\nwith doing less.', philosophyIntro: 'For an AI-driven workflow, we focus on six essentials. These full IDE features are optional trade-offs.',
    omittedTitle: 'These can stay outside the editor.',
    omitted: [
      ['Integrated build system', 'Let AI write the shell scripts. Build, test, and run them in the terminal.'],
      ['Intelligent code completion', 'Generate code with your preferred AI coding tool.'],
      ['Code and symbol navigation', 'Use the file tree, search, and text editing for everyday inspection and changes.'],
    ],
    omittedFoot: 'Need more? The source is yours. Add it with AI when you need it.',
    buildThought: 'Build it. Run it.\nA shell script can do that.', buildThoughtBody: 'Let AI write the script, then save the command. Running a project does not have to mean carrying a full IDE.',
    openTitle: 'Need a feature?\nBuild it with AI.', openDescription: 'Open source keeps the tool in your hands. Use your preferred AI coding tool to add a feature and shape vsux around the way you work.',
    openLink: 'Explore the source. Make it yours.', promptLabel: 'Start with something you need', prompt: 'Add tag-based filtering to saved commands,\nwith categories that fit my workflow.', promptFoot: 'Your idea → AI-assisted changes → Your vsux',
    start: 'Your next project. A lighter start.', build: 'Build from source', buildNote: 'macOS 14+ · Apple Silicon only.',
    footer: 'Just enough. Yours to grow.',
  },
};

function App() {
  const [lang, setLang] = useState(() => localStorage.getItem('vsux-web-language') === 'en' ? 'en' : 'zh');
  const [scene, setScene] = useState(0);
  const dialog = useRef(null);
  const site = useRef(null);
  usePageEffects(site);
  const t = copy[lang];
  const imagePath = `/assets/${scene === 0 ? 'workspace' : 'editor'}-${lang}.webp`;
  useEffect(() => {
    document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
    document.title = lang === 'zh' ? 'vsux — AI 时代，编辑器只需刚好。' : 'vsux — Just enough editor for the AI era.';
    document.querySelector('meta[name="description"]').content = t.description.replace('\n', ' ');
    localStorage.setItem('vsux-web-language', lang);
  }, [lang, t.description]);

  return <div ref={site} className="site">
    <a className="skip-link" href="#main">{t.skip}</a>
    <header className="header wrap">
      <a href="#" className="brand" aria-label="vsux"><img src="/assets/vsux-logo.png" alt="" />vsux<span className="brand-slash">/</span></a>
      <nav aria-label={lang === 'zh' ? '主导航' : 'Main navigation'}>{t.nav.map((label, i) => <a key={i} href={['#features', '#philosophy', '#open-source'][i]}>{label}</a>)}</nav>
      <div className="header-actions"><button className="language" aria-label={t.langLabel} onClick={() => setLang(lang === 'zh' ? 'en' : 'zh')}>{t.lang}</button><a className="button button-small" href={dmgRelease}>{t.primary}<span aria-hidden="true">↓</span></a></div>
    </header>
    <main id="main">
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
          <div className="screenshot-scroll"><button className="screenshot-button" onClick={() => dialog.current.showModal()} aria-label={t.zoom}><img className="product-image" src={imagePath} alt={t.imageAlt[scene]} fetchPriority="high" width="2560" height="1458" /></button></div>
          <div className="stage-controls"><div role="group" aria-label={t.gallery} className="scene-switch">{t.scenes.map((label, i) => <button key={i} aria-pressed={scene === i} onClick={() => setScene(i)}>{label}</button>)}</div><span className="image-hint">{t.imageHint}</span></div>
          <figcaption><span>{t.sample}</span><span className="mobile-hint">{t.mobileHint}</span></figcaption>
        </figure>
      </section>
      <section id="why-vsux" className="friction wrap" aria-labelledby="friction-title">
        <div className="friction-heading"><p className="eyebrow">THE IDEA BEHIND VSUX</p><h2 id="friction-title">{t.frictionTitle}</h2><p className="section-intro">{t.frictionIntro}</p></div>
        <div className="friction-grid">{t.frictionCards.map(([name, strengths, body], i) => <article key={i}>
          <h3>{name}</h3><p className="comparison-strengths">{strengths}</p><p className="comparison-pain">{body}</p>
        </article>)}</div>
        <div className="resolution"><a className="brand" href="#features"><img src="/assets/vsux-logo.png" alt="" />vsux</a><h3>{t.resolutionTitle}</h3><p>{t.resolutionBody}</p></div>
      </section>
      <section id="features" className="features wrap">
        <p className="eyebrow">THE ESSENTIALS / 01—06</p><h2>{t.features}</h2><p className="section-intro">{t.featureIntro}</p>
        <div className="feature-grid">{t.cards.map(([title, body], i) => <article key={title}><span className="feature-index">0{i + 1} /</span><h3>{title}</h3><p>{body}</p></article>)}</div>
        <article className="service-feature"><span className="feature-index">BACKGROUND SERVICES /</span><div><h3>{t.serviceTitle}</h3><p>{t.serviceBody}</p><span className="extra-detail">{t.serviceNote}</span></div></article>
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
        <div className="workflow-extras">{t.extras.map(([title, body, detail], i) => <article key={i}><span className="feature-index">{i === 0 ? '$ ./dev.sh' : '# README.md'}</span><h3>{title}</h3><p>{body}</p><span className="extra-detail">{detail}</span></article>)}</div>
      </section>
      <section id="philosophy" className="philosophy wrap">
        <div><p className="eyebrow">LESS, BY DESIGN.</p><h2>{t.philosophy}</h2><p className="section-intro">{t.philosophyIntro}</p><div className="build-thought"><h3>{t.buildThought}</h3><p>{t.buildThoughtBody}</p></div></div>
        <div className="omitted"><h3 className="omitted-heading">{t.omittedTitle}</h3><ul>{t.omitted.map(([title, body], i) => <li key={i}><span className="omitted-cross" aria-hidden="true">❌</span><div><h3>{title}</h3><p>{body}</p></div></li>)}</ul><p className="omitted-foot">{t.omittedFoot}</p></div>
      </section>
      <section id="open-source" className="open-source wrap">
        <div><p className="eyebrow">OPEN SOURCE. OPEN ENDED.</p><h2>{t.openTitle}</h2><p className="section-intro">{t.openDescription}</p><a href={repository} target="_blank" rel="noreferrer" className="text-link">{t.openLink} <span aria-hidden="true">↗</span></a></div>
        <div className="prompt-example"><span className="prompt-label">{t.promptLabel}</span><p><span aria-hidden="true">› </span>{t.prompt}</p><span className="prompt-foot">{t.promptFoot}</span></div>
      </section>
      <section id="start" className="start wrap"><div><p className="eyebrow">HELLO, VSUX.</p><h2>{t.start}</h2><p>{t.buildNote}</p><a href={`${repository}#构建和启动`} target="_blank" rel="noreferrer" className="text-link">{t.build} ↗</a></div><pre><code>./Scripts/build.sh{'\n'}open "dist/vsux.app"</code></pre></section>
    </main>
    <footer className="wrap"><a className="brand" href="#"><img src="/assets/vsux-logo.png" alt="" />vsux</a><span>{t.footer}</span><a href={repository} target="_blank" rel="noreferrer">GitHub ↗</a></footer>
    <dialog ref={dialog} className="image-dialog" aria-label={t.scenes[scene]} onClick={event => { if (event.target === dialog.current) dialog.current.close(); }}>
      <div className="dialog-toolbar"><span>{t.scenes[scene]}</span><button onClick={() => dialog.current.close()} aria-label={t.close}>×</button></div><img src={imagePath} alt={t.imageAlt[scene]} /><p>{t.sample}</p>
    </dialog>
  </div>;
}
createRoot(document.getElementById('root')).render(<React.StrictMode><App /></React.StrictMode>);
