"""Render both 1200×630 share cards. Requires Pillow; fonts are bundled under OFL."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, PngImagePlugin

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'public/assets'
FONTS = Path(__file__).resolve().parent / 'fonts'
SCALE = 2


def font(size, weight=450, chinese=False):
    face = ImageFont.truetype(str(FONTS / ('NotoSansSC-og.ttf' if chinese else 'DMSans.ttf')), size * SCALE)
    axes = face.get_variation_axes()
    face.set_variation_by_axes([weight if a['name'] == b'Weight' else a['default'] for a in axes])
    return face


def render(lang):
    zh = lang == 'zh'
    canvas = Image.new('RGB', (1200*SCALE, 630*SCALE), '#101214')
    d = ImageDraw.Draw(canvas)

    def text(x, y, value, size, color='#F3F4F5', weight=450, chinese=False):
        d.text((x*SCALE, y*SCALE), value, font=font(size, weight, chinese), fill=color, anchor='lt')

    logo = Image.open(ASSETS / 'vsux-logo-large.png').convert('RGBA')
    # Trim the transparent export padding, preserving the app icon itself.
    logo = logo.crop(logo.getbbox()).resize((60*SCALE, 60*SCALE), Image.Resampling.LANCZOS)
    canvas.paste(logo, (64*SCALE, 52*SCALE), logo)
    text(140, 60, 'vsux', 44, weight=650)
    text(64, 167, '多个项目，' if zh else 'More projects.', 54 if zh else 50, weight=650, chinese=zh)
    text(64, 241, '一个工作区。' if zh else 'One workspace.', 54 if zh else 50, color='#59BAFF', weight=650, chinese=zh)
    text(64, 343, '一款轻量编辑器' if zh else 'A lightweight editor', 23, chinese=zh)
    text(64, 379, '围绕终端，留下日常所需。' if zh else 'for parallel projects on macOS.', 19, '#AAB1BA', chinese=zh)

    # The current real app capture is shown without a fabricated window frame.
    shot = Image.open(ASSETS / f'workspace-{lang}.webp').convert('RGB')
    w = 760*SCALE
    shot = shot.resize((w, round(shot.height*w/shot.width)), Image.Resampling.LANCZOS)
    mask = Image.new('L', shot.size)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, shot.width, shot.height), radius=12*SCALE, fill=255)
    canvas.paste(shot, (528*SCALE, 182*SCALE), mask)

    d.line((64*SCALE, 484*SCALE, 448*SCALE, 484*SCALE), fill='#30363D', width=SCALE)
    d.ellipse((64*SCALE, 517*SCALE, 72*SCALE, 525*SCALE), fill='#59BAFF')
    text(84, 509, '免费开源 · MIT' if zh else 'Free & open source · MIT', 20, weight=550, chinese=zh)
    text(64, 554, 'macOS 14+  /  Apple Silicon', 17, '#AAB1BA')
    text(528, 93, 'github.com/shadowDragons/vsux', 18, '#AAB1BA')

    info = PngImagePlugin.PngInfo()
    info.add_text('Source', f'Composed by scripts/generate-og.py; native screenshot: assets/workspace-{lang}.webp; logo: app resource; DM Sans / Noto Sans SC under OFL.')
    canvas = canvas.resize((1200,630), Image.Resampling.LANCZOS)
    canvas.save(ASSETS / f'og-{lang}.png', pnginfo=info, optimize=True)


for locale in ('zh', 'en'):
    render(locale)
