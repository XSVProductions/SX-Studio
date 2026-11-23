#!/usr/bin/env python3
"""Builds the SX Helper DEMO (no laptop needed) into _site/demo/ for GitHub Pages.

It is the Helper's real phone page (the $html block in src/df_aim_gui.ps1) with demo/demo_api.js in front of it:
a pretend laptop that answers every /api/ call with a made-up show, so nothing reaches ShowXpress or the lights.
It can be added to the iPhone / iPad Home Screen (full screen, own icon) and works offline (sw.js).
Run:  python3 demo/build_demo.py   (from the repo root)  ->  _site/demo/
"""
import hashlib, json, os, re, shutil, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, '_site', 'demo')


def main():
    src = open(os.path.join(ROOT, 'src', 'df_aim_gui.ps1'), encoding='utf-8-sig').read()
    a = src.index("$html = @'\n") + len("$html = @'\n")
    h = src[a:src.index("\n'@\n", a)]
    ver = open(os.path.join(ROOT, 'src', 'version.txt')).read().strip() if os.path.exists(os.path.join(ROOT, 'src', 'version.txt')) else ''
    api = open(os.path.join(ROOT, 'demo', 'demo_api.js'), encoding='utf-8').read()

    def rep(old, new, count=None):
        nonlocal h
        n = h.count(old)
        if not n or (count is not None and n != count):
            sys.exit(f'build_demo: expected {count or "some"} of {old[:60]!r} in the page, found {n} - update demo/build_demo.py')
        h = h.replace(old, new)

    rep('/icon.png?t=__TOKEN__', 'icon.png')
    rep('src="/icon.png"', 'src="icon.png"')
    rep('href="/icon.png"', 'href="icon.png"')
    rep('<title>SX Helper</title>', '<title>SX Helper – Demo</title>', 1)
    rep('content="SX Helper"', 'content="SX Demo"', 1)
    rep('<link rel="apple-touch-icon" href="icon.png">', '<link rel="apple-touch-icon" href="icon.png"><link rel="manifest" href="manifest.webmanifest">', 1)
    rep("if(__PHONE__){let ls='';try{ls=localStorage.getItem('sxh_phone_key')||'';}catch(e){}\n"
        " const uk=new URLSearchParams(location.search).get('k')||'',ck='__PHONEKEY__';\n"
        " T=ck||uk||ls;   // the server only fills ck with the CURRENT key, so it wins over an old one\n"
        " if(T){phKeep(T);}}", "T='demo';", 1)
    rep('__PHONE__', 'true')
    rep("'__TOKEN__'", "''")
    rep('<h1 id="ttl" style="cursor:pointer" title="Home">SX Helper</h1>',
        '<h1 id="ttl" style="cursor:pointer" title="Home">SX Helper <span class="tag amber" style="font-size:11px;vertical-align:2px">DEMO</span></h1>', 1)
    rep(' <div class="view" id="v-home">\n  <section class="card">',
        ' <div class="view" id="v-home">\n  <section class="card" style="border-color:rgba(255,176,32,.45);background:rgba(255,176,32,.06)">'
        '<h2>&#9888; Demo &mdash; not connected to a laptop</h2><p class="sub" style="margin:0">A pretend show with 10 movers, so you can try every screen: '
        'tap heads, save, aim live with your finger, start the Auto Show. Nothing is sent to ShowXpress or the lights, and it works without internet. '
        'The APC mini and Speed Faders tabs only work on the real laptop. For the real thing, open the address the Helper shows on the laptop '
        '(&#9881; Settings &rarr; Phone &amp; iPad).</p></section>\n  <section class="card">', 1)
    rep('<script>\n', '<script>\n' + api + "\ntry{if('serviceWorker' in navigator)navigator.serviceWorker.register('sw.js');}catch(e){}\n</script>\n<script>\n", 1)
    if re.search(r'__PHONE__|__PHONEKEY__|__TOKEN__', h):
        sys.exit('build_demo: a placeholder is left in the page')

    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)
    open(os.path.join(OUT, 'index.html'), 'w', encoding='utf-8').write(h)
    shutil.copy(os.path.join(ROOT, 'assets', 'aim_movers_1024.png'), os.path.join(OUT, 'icon.png'))
    json.dump({'name': 'SX Helper Demo', 'short_name': 'SX Demo', 'start_url': './', 'scope': './', 'display': 'standalone',
               'background_color': '#0e1014', 'theme_color': '#0e1014',
               'icons': [{'src': 'icon.png', 'sizes': '1024x1024', 'type': 'image/png', 'purpose': 'any'}]},
              open(os.path.join(OUT, 'manifest.webmanifest'), 'w'), indent=1)
    # offline: keep the three files; a new build (new hash) replaces them the next time the demo is opened online
    tag = hashlib.sha1((h + ver).encode()).hexdigest()[:12]
    open(os.path.join(OUT, 'sw.js'), 'w').write(f"""const C='sxh-demo-{tag}',F=['./','index.html','icon.png','manifest.webmanifest'];
self.addEventListener('install',e=>{{e.waitUntil(caches.open(C).then(c=>c.addAll(F)).then(()=>self.skipWaiting()));}});
self.addEventListener('activate',e=>{{e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x!==C).map(x=>caches.delete(x)))).then(()=>self.clients.claim()));}});
self.addEventListener('fetch',e=>{{if(e.request.method!=='GET')return;
 e.respondWith(fetch(e.request).then(r=>{{if(r.ok){{const c=r.clone();caches.open(C).then(x=>x.put(e.request,c));}}return r;}}).catch(()=>caches.match(e.request,{{ignoreSearch:true}}).then(r=>r||caches.match('index.html'))));}});
""")
    # a landing page at the site root that sends people to the demo
    open(os.path.join(ROOT, '_site', 'index.html'), 'w').write('<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="0;url=demo/">'
                                                              '<title>SX Helper</title><a href="demo/">SX Helper demo</a>')
    print('built', OUT, tag)


if __name__ == '__main__':
    main()
