# SX Studio logo + app icon (user 2026-11-24: the new logo; the icon is black and white, only the mark).
# The source is the user's picture: the chrome SX mark over STUDIO on pure black (assets/sx_studio_logo.jpg).
# usage: python tools/make_sx_brand.py [<outdir> = assets]
#   sx_logo.png          the whole logo (mark + STUDIO), see-through - Home page
#   sx_mark.png          the SX mark only, see-through - the header
#   aim_movers_1024.png  app icon picture (Mac .icns, phone home screen)
#   aim_movers.ico       Windows icon (16-256 px)
#   brand_preview.png    a look at all of them
import os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'assets', 'sx_studio_logo.jpg')
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'assets')
GLOW = (255, 255, 255)   # black and white icon (user 2026-11-24): a faint white light, no colour

src = Image.open(SRC).convert('RGB')

def cutout(im, full=90):
    """Black -> see-through. A pixel as bright as `full` (max channel) or more is solid; darker ones are the
    anti-aliased edge, so their colour is un-premultiplied and they fade out instead of leaving a dark fringe."""
    r, g, b = im.split()
    mx = ImageChops.lighter(ImageChops.lighter(r, g), b)
    a = mx.point(lambda v: min(255, v * 255 // full))
    px = im.load(); ap = a.load(); w, h = im.size
    o = Image.new('RGBA', (w, h)); op = o.load()
    for y in range(h):
        for x in range(w):
            al = ap[x, y]
            if not al: op[x, y] = (0, 0, 0, 0); continue
            c = px[x, y]
            if al < 255:
                f = 255 / al; c = tuple(min(255, int(v * f)) for v in c)
            op[x, y] = (c[0], c[1], c[2], al)
    return o

def bbox(im):
    return im.getchannel('A').point(lambda v: 255 if v > 8 else 0).getbbox()

def gap_rows(im):
    """the empty band between the mark and STUDIO"""
    a = im.getchannel('A').point(lambda v: 255 if v > 8 else 0); w, h = a.size
    on = [a.crop((0, y, w, y + 1)).getbbox() is not None for y in range(h)]
    best, run, start = (0, 0), 0, 0
    first = on.index(True)
    for y in range(first, h):
        if not on[y]:
            if run == 0: start = y
            run += 1
            if run > best[1] - best[0]: best = (start, y + 1)
        else: run = 0
    return best

logo = cutout(src); logo = logo.crop(bbox(logo))
g0, g1 = gap_rows(logo)
mark = logo.crop((0, 0, logo.width, g0)); mark = mark.crop(bbox(mark))

def fit_h(im, h):
    return im.resize((round(im.width * h / im.height), h), Image.LANCZOS)

fit_h(logo, 440).save(os.path.join(out, 'sx_logo.png'), optimize=True)
fit_h(mark, 256).save(os.path.join(out, 'sx_mark.png'), optimize=True)

def icon(n, pad):
    M = n * 4
    bg = Image.new('RGBA', (M, M), (0, 0, 0, 0)); d = ImageDraw.Draw(bg); r = int(M * 0.2)
    d.rounded_rectangle((0, 0, M - 1, M - 1), r, fill=(14, 16, 22, 255))
    # a faint white light from the top-left, like a beam
    glow = Image.new('L', (M, M), 0); ImageDraw.Draw(glow).ellipse((-M * .35, -M * .55, M * .75, M * .45), fill=26)
    glow = glow.filter(ImageFilter.GaussianBlur(M * 0.12))
    lt = Image.new('RGBA', (M, M), GLOW + (255,)); lt.putalpha(glow)
    sq = Image.new('L', (M, M), 0); ImageDraw.Draw(sq).rounded_rectangle((0, 0, M - 1, M - 1), r, fill=255)
    bg.paste(Image.alpha_composite(bg, lt), (0, 0), sq)
    ImageDraw.Draw(bg).rounded_rectangle((2, 2, M - 3, M - 3), r, outline=GLOW + (55,), width=max(2, M // 200))
    side = M * (1 - 2 * pad); sc = min(side / mark.width, side / mark.height)
    mk = mark.resize((round(mark.width * sc), round(mark.height * sc)), Image.LANCZOS)
    ox, oy = (M - mk.width) // 2, (M - mk.height) // 2
    sh = Image.new('RGBA', (M, M), (0, 0, 0, 0)); a = Image.new('L', (M, M), 0); a.paste(mk.getchannel('A'), (ox, oy + M // 120))
    sh.putalpha(a.filter(ImageFilter.GaussianBlur(M * 0.012)).point(lambda v: v * 8 // 10))
    bg = Image.alpha_composite(bg, sh); bg.alpha_composite(mk, (ox, oy))
    return bg.resize((n, n), Image.LANCZOS)

big = icon(1024, 0.15); big.save(os.path.join(out, 'aim_movers_1024.png'), optimize=True)
sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
ims = [icon(s, 0.08 if s <= 48 else 0.13) for s in sizes]
ims[-1].save(os.path.join(out, 'aim_movers.ico'), sizes=[(s, s) for s in sizes], append_images=ims[:-1])

pv = Image.new('RGBA', (1024 + 256 + 64 + 48 + 32 + 16 + 120, 1024 + 480), (40, 40, 40, 255)); x = 0
for im in [big, ims[-1], ims[6], ims[5], ims[3], ims[0]]:
    pv.alpha_composite(im, (x, 0)); x += im.width + 20
lg = fit_h(logo, 440); pv.alpha_composite(lg, (20, 1044))
light = Image.new('RGBA', (lg.width + 40, 480), (238, 240, 244, 255)); pv.alpha_composite(light, (lg.width + 60, 1024))
pv.alpha_composite(lg, (lg.width + 80, 1044))
pv.save(os.path.join(out, 'brand_preview.png') if out != os.path.join(ROOT, 'assets') else os.path.join(os.environ.get('TEMP', '.'), 'brand_preview.png'))
print('logo', lg.size, 'mark', fit_h(mark, 256).size)
