"""Adapt the approved Chinese OG composition to portrait/landscape covers.

Run from any directory with Pillow installed. Uses the same licensed fonts,
logo and unaltered native screenshot as generate-og.py.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, PngImagePlugin

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'public/assets'
FONTS = Path(__file__).resolve().parent / 'fonts'
OUT = ASSETS / 'covers'
SCALE = 2
INK, BLUE, MUTED = '#F3F4F5', '#59BAFF', '#AAB1BA'


def font(size, weight=450, chinese=False):
    filename = 'NotoSansSC-og.ttf' if chinese else 'DMSans.ttf'
    face = ImageFont.truetype(str(FONTS / filename), round(size*SCALE))
    face.set_variation_by_axes([
        weight if a['name'] == b'Weight' else a['default']
        for a in face.get_variation_axes()
    ])
    return face


def render(portrait):
    width, height = (1200, 1600) if portrait else (1600, 1200)
    canvas = Image.new('RGB', (width*SCALE, height*SCALE), '#101214')
    d = ImageDraw.Draw(canvas)

    def text(x, y, value, size, color=INK, weight=450, chinese=False):
        face = font(size, weight, chinese)
        bounds = d.textbbox((x*SCALE, y*SCALE), value, font=face, anchor='lt')
        assert bounds[0] >= 0 and bounds[2] <= width*SCALE, value
        assert bounds[1] >= 0 and bounds[3] <= height*SCALE, value
        d.text((x*SCALE, y*SCALE), value, font=face, fill=color, anchor='lt')

    margin = 80 if portrait else 140
    logo_size = 76 if portrait else 64
    logo_y = 80 if portrait else 56
    logo = Image.open(ASSETS / 'vsux-logo-large.png').convert('RGBA')
    logo = logo.crop(logo.getbbox()).resize((logo_size*SCALE, logo_size*SCALE), Image.Resampling.LANCZOS)
    canvas.paste(logo, (margin*SCALE, logo_y*SCALE), logo)
    text(margin+logo_size+22, logo_y+6, 'vsux', 56 if portrait else 48, weight=650)

    if portrait:
        text(margin, 230, '多个项目，', 96, weight=650, chinese=True)
        text(margin, 354, '一个工作区。', 96, BLUE, 650, True)
        text(margin, 520, '一款轻量编辑器', 36, chinese=True)
        text(margin, 580, '围绕终端，留下日常所需。', 28, MUTED, chinese=True)
        shot_y = 700
        shot_width = 1040
    else:
        text(margin, 176, '多个项目，', 82, weight=650, chinese=True)
        prefix_width = d.textlength('多个项目，', font=font(82, 650, True))/SCALE
        text(margin+prefix_width, 176, '一个工作区。', 82, BLUE, 650, True)
        text(margin, 286, '一款轻量编辑器', 28, chinese=True)
        text(margin+260, 286, '围绕终端，留下日常所需。', 26, MUTED, chinese=True)
        shot_y = 360
        shot_width = 1320

    shot = Image.open(ASSETS / 'workspace-zh.webp').convert('RGB')
    shot_height = round(shot.height*shot_width/shot.width)
    shot = shot.resize((shot_width*SCALE, shot_height*SCALE), Image.Resampling.LANCZOS)
    mask = Image.new('L', shot.size)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, shot.width, shot.height), radius=14*SCALE, fill=255)
    canvas.paste(shot, (margin*SCALE, shot_y*SCALE), mask)

    if portrait:
        rule_y = 1370
        d.line((margin*SCALE, rule_y*SCALE, (width-margin)*SCALE, rule_y*SCALE), fill='#30363D', width=SCALE)
        text(margin, 1410, '免费开源 · MIT', 30, weight=550, chinese=True)
        text(margin, 1470, 'macOS 14+  /  Apple Silicon', 25, MUTED)
        text(width-margin-d.textlength('vsux.sphrag.com', font=font(26))/SCALE, 1528, 'vsux.sphrag.com', 26, MUTED)
    else:
        text(margin, 1138, '免费开源 · MIT', 26, weight=550, chinese=True)
        text(margin+340, 1138, 'macOS 14+  /  Apple Silicon', 24, MUTED)
        domain = 'vsux.sphrag.com'
        text(width-margin-d.textlength(domain, font=font(24))/SCALE, 1138, domain, 24, MUTED)

    info = PngImagePlugin.PngInfo()
    info.add_text('Source', 'Adapted from approved og-zh.png layout using generate-covers.py. Actual native UI: workspace-zh.webp; original app logo; DM Sans and Noto Sans SC under OFL. Full screenshot preserved, fictional demo data.')
    info.add_text('Website', 'https://vsux.sphrag.com/')
    canvas = canvas.resize((width, height), Image.Resampling.LANCZOS)
    name = f'vsux-cover-zh-{3 if portrait else 4}x{4 if portrait else 3}.png'
    OUT.mkdir(exist_ok=True)
    canvas.save(OUT/name, pnginfo=info, optimize=True)
    print(OUT/name)


if __name__ == '__main__':
    render(True)
    render(False)
