"""Export approved Cinecode shots; only crop and translate labels for the website."""
from pathlib import Path
import json
import subprocess

ROOT = Path(__file__).resolve().parents[2]
FILM = ROOT / '广告/vsux-30s'
OUT = ROOT / 'web/public/assets/story'
existing_provenance = json.loads((OUT / 'provenance.json').read_text()) if (OUT / 'provenance.json').exists() else {}
SHOTS = [('parallel', 12.5), ('overhead', 40.5), ('comparison', 49.8), ('essentials', 53.5)]
LABELS = {
    '界面示意': 'Illustration',
    '项目 A · 改页面': 'Project A · Page', '项目 B · 跑测试': 'Project B · Tests',
    '项目 C · 看效果': 'Project C · Preview', '服务运行中': 'Service running',
    '项目 A': 'Project A', '项目 B': 'Project B', '项目 C': 'Project C',
    '语言服务 + 扩展插件': 'Language services + extensions',
    '多窗口 + 完整环境 + 插件叠加，内存很快吃紧': 'More windows, full environments and extensions add up.',
    '我的多项目旧方式': 'My previous setup', '我想要的多项目方式': 'What I want to keep',
    '每个项目，一套完整环境': 'A full setup for every project',
    '围绕项目，保留常用操作': 'Projects and everyday tools',
    '完整补全 UI': 'Completion UI', '代码导航引擎': 'Code navigation',
    '语言服务': 'Language services', '各种扩展插件': 'Extensions',
    '精简我不需要的': 'Leave out the tools', '复杂编辑器功能': 'I no longer need',
    '多项目工作区 + 终端分屏': 'Workspaces + split terminals',
    '文件 / Git / 日常检查': 'Files / Git / review', '命令 / 后台服务': 'Commands / services',
    '编译和检查仍执行，交给 AI 在终端跑。': 'Builds and checks still run in the terminal.',
}

OUT.mkdir(parents=True, exist_ok=True)
source = (FILM / 'film.html').read_text()
records = []
for language in ('zh', 'en'):
    content = source
    if language == 'en':
        # Same scene geometry, frame and state; only visible labels are localized.
        for original, translated in sorted(LABELS.items(), key=lambda item: -len(item[0])):
            content = content.replace(original, translated)
        content = content.replace('35,INK,600);', '32,INK,600);')
    page = FILM / f'.web-stills-{language}.html'
    page.write_text(content)
    try:
        result = subprocess.run([
            'python3', 'tools/make.py', 'stills', '--film', page.name,
            '--size', '3840x2160', '--at', ','.join(str(time) for _, time in SHOTS),
        ], cwd=FILM, text=True, capture_output=True, check=True)
        first = result.stdout.splitlines()[0]
        sheet = first.split('stills: ', 1)[1].split(' (', 1)[0]
        frames = FILM / Path(sheet).with_suffix('')
        for name, time in SHOTS:
            frame = frames / f'{round(time * 24):06d}.jpg'
            target = OUT / f'{name}-{language}.png'
            subprocess.run([
                'ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', str(frame),
                '-vf', 'crop=1720:568:100:310', '-frames:v', '1',
                '-c:v', 'png', '-map_metadata', '-1', str(target),
            ], check=True)
            records.append({'file': target.relative_to(ROOT / 'web/public').as_posix(),
                            'time': time, 'frame': round(time * 24), 'language': language,
                            'kind': 'Workflow illustration from approved ad',
                            'crop': [100, 310, 1720, 568]})
        target = OUT / f'project-tools-{language}.png'
        subprocess.run([
            'ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
            '-i', str(ROOT / f'web/public/assets/workspace-{language}.webp'),
            '-vf', 'crop=470:764:2062:238', '-frames:v', '1', '-map_metadata', '-1', str(target),
        ], check=True)
        records.append({'file': target.relative_to(ROOT / 'web/public').as_posix(),
                        'source': f'assets/workspace-{language}.webp',
                        'crop': [2062, 238, 470, 764],
                        'kind': 'Actual native UI crop; fictional demo project'})
        print(f'{language}: exported {len(SHOTS)} approved shots and a native UI crop')
    finally:
        page.unlink(missing_ok=True)
(OUT / 'provenance.json').write_text(json.dumps({
    'source': 'Approved vsux-focus v16 Cinecode composition',
    'modifications': 'Caption/header crop; English labels localized in the same composition. No AI-generated images.',
    'images': records,
    **({'github': existing_provenance['github']} if 'github' in existing_provenance else {}),
}, ensure_ascii=False, indent=2) + '\n')
