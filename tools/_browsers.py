import sys, json
from playwright.sync_api import sync_playwright

url = "file:///F:/aiprojects/paperdoll-like/tools/character_designer.html"

def probe(pw, name, launcher, vp):
    try:
        b = launcher.launch()
    except Exception as e:
        print(name, "SKIP:", str(e)[:80].splitlines()[0])
        return
    pg = b.new_page(viewport=vp)
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.on("console", lambda m: errs.append(m.type + ": " + m.text) if m.type == "error" else None)
    pg.goto(url)
    pg.wait_for_timeout(2000)
    info = pg.evaluate("""()=>({
        cvw: document.getElementById('cv').width,
        cvh: document.getElementById('cv').height,
        secs: document.querySelectorAll('.lsec').length,
        chips: document.querySelectorAll('.lchip').length,
        px: (()=>{ const s=document.createElement('canvas'); s.width=256; s.height=256;
             const g=s.getContext('2d'); g.drawImage(document.getElementById('cv'),0,0,256,256);
             const d=g.getImageData(0,0,256,256).data; let n=0;
             for(let i=3;i<d.length;i+=4) if(d[i]>8) n++;
             return n; })()
    })""")
    pg.screenshot(path="F:/aiprojects/paperdoll-like/docs/_probe_%s.png" % name)
    print(name, vp, json.dumps(info), "ERR:", json.dumps(errs[:5], ensure_ascii=False))
    b.close()

with sync_playwright() as p:
    probe(p, "chromium", p.chromium, {"width": 1280, "height": 800})
    probe(p, "firefox", p.firefox, {"width": 1280, "height": 800})
    probe(p, "webkit", p.webkit, {"width": 1280, "height": 800})
