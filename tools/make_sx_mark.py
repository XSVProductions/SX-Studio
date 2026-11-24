# SX Studio mark (2026-11-23): the X traced from the user's reference picture, the S drawn to match it.
# usage: python make_sx_mark.py <outdir>  -> sx_mark.svg, sx_icon_1024.png (= assets/aim_movers_1024.png), sx_icon.ico (= assets/aim_movers.ico)
from PIL import Image, ImageDraw
X = [[(158,277),(285,277),(355,378),(122,590),(285,385),(218,290)],
     [(612,145),(358,303),(310,278),(372,363)],
     [(367,397),(432,488),(490,500),(372,502),(338,458),(283,472)]]
K = 0.69   # the X's arm slant (dx per dy)
def isect(a, b):  # lines as (x0, slope) meaning x = x0 + slope*y  -> point
    y = (b[0]-a[0])/(a[1]-b[1]); return (a[0]+a[1]*y, y)
def make_S(s=2.0, th=56, bt=36, cx=110, H=225, ext=34, g=5, xbar=None):
    cy = H/2
    sp_out = (cx - th/2 - s*cy, s)        # spine lower-left edge
    sp_in  = (cx + th/2 - s*cy, s)        # spine upper-right edge
    # shoulder outer edge x = xtl - K*y must meet the spine outer edge at x=0
    yL = (0 - sp_out[0]) / s; xtl = K*yL
    sh_out = (xtl, -K); sh_in = (xtl + th, -K)
    L = (0, yL); Li = isect(sh_in, sp_in)
    W = 2*cx
    bi = (sh_in[0] - K*bt, bt)           # bar underside meets shoulder inner edge
    # gap: line through centre along the X's long slash (dy/dx = -0.908) -> x = cx -/+ g + (cy - y)/0.908
    gl = (cx - g + cy/0.908, -1/0.908)
    U = [(xtl,0),(W-10,0),(W+ext,-8),(W-40,bt),bi,Li, isect(sp_in, gl), isect(sp_out, gl), L]
    R = [(W-x, H-y) for x,y in U]
    return [U, R], W
from PIL import ImageFilter
import sys, os
S, W = make_S(s=2.0, th=66, bt=42)
polys = [[(x, y+277) for x,y in p] for p in S] + [[(x + W + 70 - 158, y) for x,y in p] for p in X]
xs = [x for p in polys for x,y in p]; ys = [y for p in polys for x,y in p]
x0, y0, x1, y1 = min(xs), min(ys), max(xs), max(ys)
polys = [[(round(x-x0,1), round(y-y0,1)) for x,y in p] for p in polys]
bw, bh = x1-x0, y1-y0
out = sys.argv[1]
# --- SVG (chrome gradient; currentColor-free so it looks the same everywhere)
svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {bw:.0f} {bh:.0f}">',
 f'<defs><linearGradient id="c" gradientUnits="userSpaceOnUse" x1="0" y1="{277-8-y0:.0f}" x2="0" y2="{502+8-y0:.0f}">',
 '<stop offset="0" stop-color="#ffffff"/><stop offset=".45" stop-color="#c9ced6"/><stop offset=".55" stop-color="#8d939c"/><stop offset="1" stop-color="#e6e9ee"/>',
 '</linearGradient></defs><g fill="url(#c)">']
for p in polys: svg.append('<polygon points="' + ' '.join(f'{x:g},{y:g}' for x,y in p) + '"/>')
svg.append('</g></svg>')
open(os.path.join(out, 'sx_mark.svg'), 'w').write('\n'.join(svg))
# --- icon: near-black rounded square, chrome mark, thin amber rim glow
N = 1024; ss = 2; M = N*ss
def chrome(w, h):
    g = Image.new('RGB', (1, h))
    stops = [(0,(255,255,255)),(.45,(201,206,214)),(.55,(141,147,156)),(1,(230,233,238))]
    for yy in range(h):
        t = yy/(h-1)
        for (a,ca),(b,cb) in zip(stops, stops[1:]):
            if a <= t <= b:
                f = (t-a)/(b-a); g.putpixel((0,yy), tuple(int(ca[i]+(cb[i]-ca[i])*f) for i in range(3))); break
    return g.resize((w, h))
def icon(size_px, pad_frac, name=None):
    M = size_px*4
    bg = Image.new('RGBA', (M, M), (0,0,0,0)); d = ImageDraw.Draw(bg)
    r = int(M*0.2)
    d.rounded_rectangle((0,0,M-1,M-1), r, fill=(14,16,22,255))
    # soft amber light from the top-left, like a beam
    glow = Image.new('L', (M, M), 0); gd = ImageDraw.Draw(glow)
    gd.ellipse((-M*0.35, -M*0.55, M*0.75, M*0.45), fill=60)
    glow = glow.filter(ImageFilter.GaussianBlur(M*0.12))
    amber = Image.new('RGBA', (M, M), (255,176,32,255)); amber.putalpha(glow)
    mask_sq = Image.new('L', (M, M), 0); ImageDraw.Draw(mask_sq).rounded_rectangle((0,0,M-1,M-1), r, fill=255)
    tmp = Image.alpha_composite(bg, amber); bg.paste(tmp, (0,0), mask_sq)
    d = ImageDraw.Draw(bg); d.rounded_rectangle((2,2,M-3,M-3), r, outline=(255,176,32,90), width=max(2, M//200))
    # mark
    sc = (M*(1-2*pad_frac))/bw; ox = (M - bw*sc)/2; oy = (M - bh*sc)/2
    mk = Image.new('L', (M, M), 0); md = ImageDraw.Draw(mk)
    for p in polys: md.polygon([(ox+x*sc, oy+y*sc) for x,y in p], fill=255)
    top, bot = int(oy + (277-y0-8)*sc), int(oy + (502-y0+8)*sc)
    ch = Image.new('RGBA', (M, M), (230,233,238,255)); ch.paste(chrome(M, bot-top), (0, top))
    shadow = Image.new('RGBA', (M, M), (0,0,0,255)); shadow.putalpha(mk.filter(ImageFilter.GaussianBlur(M*0.012)).point(lambda v: v*0.8))
    bg = Image.alpha_composite(bg, shadow)
    ch.putalpha(mk); bg = Image.alpha_composite(bg, ch)
    return bg.resize((size_px, size_px), Image.LANCZOS)
big = icon(1024, 0.12); big.save(os.path.join(out, 'sx_icon_1024.png'))
sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
ims = [icon(s, 0.06 if s <= 48 else 0.10) for s in sizes]
ims[-1].save(os.path.join(out, 'sx_icon.ico'), sizes=[(s,s) for s in sizes], append_images=ims[:-1])
icon(180, 0.10).save(os.path.join(out, 'sx_icon_180.png'))
# preview strip
pv = Image.new('RGBA', (1024+256+48+32+16+80, 1024), (40,40,40,255)); x=0
for im in [big, ims[-1], ims[5], ims[3], ims[0]]:
    pv.alpha_composite(im, (x, 0)); x += im.size[0]+20
pv.save(os.path.join(out, 'preview.png'))
print(bw, bh)
