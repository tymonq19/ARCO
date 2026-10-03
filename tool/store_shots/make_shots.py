"""App Store screenshots: each game screenshot in an iPhone frame under a headline.

    python3 tool/store_shots/make_shots.py <folder with the 5 PNGs> [out folder] [WxH]

The PNGs are taken in name order (IMG_0259 … IMG_0264). Output is 1320x2868,
the 6.9" iPhone size App Store Connect asks for, one set in Polish and one
in English. Pass 1284x2778 (or 1242x2688) for the 6.5" slot; everything is
laid out in proportion to the width.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1320, 2868


def px(v):
    """A length designed at 1320 wide, at the current width."""
    return round(v * W / 1320)
FONT = "/System/Library/Fonts/SFNS.ttf"

# In the order the screens should appear in the store, keyed by source file
# position (0 = first file by name): headline PL, headline EN, accent glow.
SHOTS = [
    (4, "Utrzymaj piłkę\nw kole", "Keep the ball\nin the ring", (90, 190, 255)),
    (3, "Łap gwiazdy,\nmnóż punkty", "Catch stars,\nmultiply your score", (110, 170, 255)),
    (1, "Walcz o miejsce\nna świecie", "Climb the\nworld leaderboard", (150, 130, 255)),
    (2, "Jedna piłka\nczy dwie?", "One ball\nor two?", (120, 170, 255)),
    (0, "Motywy, piłki\ni paletki", "Themes, balls\nand paddles", (170, 140, 255)),
]


def font(size, weight=800):
    # SF's axes are width, optical size, grade, weight — in that order.
    f = ImageFont.truetype(FONT, size)
    try:
        f.set_variation_by_axes([100, 96, 400, weight])
    except Exception:
        pass
    return f


def background(accent):
    """Deep navy, the game's own, with a soft glow of the screen's accent."""
    img = Image.new("RGB", (W, H), (9, 11, 18))
    top = Image.new("RGB", (W, H), (20, 26, 44))
    mask = Image.linear_gradient("L").resize((W, H)).point(lambda v: 255 - v)
    img = Image.composite(top, img, mask)
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(glow)
    d.ellipse((W * 0.10, H * 0.28, W * 0.90, H * 0.80), fill=accent + (60,))
    glow = glow.filter(ImageFilter.GaussianBlur(px(240)))
    img.paste(glow, (0, 0), glow)
    return img


def phone(shot, screen_w):
    """An iPhone-like frame: titanium edge, black bezel, Dynamic Island."""
    ratio = shot.height / shot.width
    screen_h = round(screen_w * ratio)
    bezel, edge = px(26), px(8)
    pw, ph = screen_w + 2 * (bezel + edge), screen_h + 2 * (bezel + edge)
    r_out = round(screen_w * 0.165)
    frame = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))
    d = ImageDraw.Draw(frame)
    d.rounded_rectangle((0, 0, pw - 1, ph - 1), r_out, fill=(78, 82, 92))
    d.rounded_rectangle((3, 3, pw - 4, ph - 4), r_out - 3, fill=(46, 49, 56))
    d.rounded_rectangle((edge, edge, pw - edge - 1, ph - edge - 1), r_out - edge,
                        fill=(4, 4, 6))
    screen = shot.convert("RGB").resize((screen_w, screen_h), Image.LANCZOS)
    m = Image.new("L", (screen_w, screen_h), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, screen_w - 1, screen_h - 1),
                                        r_out - edge - bezel + 6, fill=255)
    frame.paste(screen, (edge + bezel, edge + bezel), m)
    iw, ih = round(screen_w * 0.29), round(screen_w * 0.085)
    ix, iy = (pw - iw) // 2, edge + bezel + round(screen_w * 0.028)
    d.rounded_rectangle((ix, iy, ix + iw, iy + ih), ih // 2, fill=(0, 0, 0))
    # Side buttons.
    for y0, y1 in ((0.17, 0.21), (0.25, 0.32), (0.34, 0.41)):
        d.rounded_rectangle((0, ph * y0, 4, ph * y1), 2, fill=(70, 74, 84))
    d.rounded_rectangle((pw - 5, ph * 0.27, pw - 1, ph * 0.38), 2,
                        fill=(70, 74, 84))
    return frame


def compose(shot, headline, accent):
    img = background(accent)
    d = ImageDraw.Draw(img)
    f = font(px(112), 800)
    d.multiline_text((W / 2, px(310)), headline, font=f, fill=(244, 246, 252),
                     anchor="mm", align="center", spacing=px(18))
    frame = phone(shot, px(960))
    m = px(100)
    shadow = Image.new("RGBA", (frame.width + 2 * m, frame.height + 2 * m), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (m, m + px(20), frame.width + m, frame.height + m), px(160), fill=(0, 0, 0, 170))
    shadow = shadow.filter(ImageFilter.GaussianBlur(px(50)))
    x = (W - frame.width) // 2
    y = px(580)
    img.paste(shadow, (x - m, y - m), shadow)
    img.paste(frame, (x, y), frame)
    return img


def main():
    src = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("build/store_shots")
    if len(sys.argv) > 3:
        global W, H
        W, H = (int(v) for v in sys.argv[3].lower().split("x"))
    files = sorted(p for p in src.iterdir() if p.suffix.lower() in (".png", ".jpg", ".jpeg"))
    if len(files) < 5:
        sys.exit(f"need 5 screenshots in {src}, found {len(files)}")
    for lang in ("pl", "en"):
        (out / lang).mkdir(parents=True, exist_ok=True)
    for n, (index, pl, en, accent) in enumerate(SHOTS, start=1):
        shot = Image.open(files[index])
        for lang, text in (("pl", pl), ("en", en)):
            path = out / lang / f"{n:02d}.png"
            compose(shot, text, accent).save(path, optimize=True)
            print(path)


if __name__ == "__main__":
    main()
