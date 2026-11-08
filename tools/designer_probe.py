import sys, json
from playwright.sync_api import sync_playwright

url = "file:///F:/aiprojects/paperdoll-like/tools/character_designer.html"
out = sys.argv[1] if len(sys.argv) > 1 else "F:/aiprojects/paperdoll-like/docs/_shot3.png"

with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1600, "height": 950}, device_scale_factor=1)
    errs = []
    pg.on("console", lambda m: errs.append(m.type + ": " + m.text))
    pg.on("pageerror", lambda e: errs.append("pageerror: " + str(e)))
    pg.goto(url)
    pg.wait_for_timeout(2500)

    def chips_of(sec_title):
        return pg.evaluate("""(t)=>{
          const secs=[...document.querySelectorAll('.lsec')];
          const s=secs.find(x=>x.querySelector('.ln').textContent===t);
          return s? [...s.querySelectorAll('.lchip')].map(c=>c.querySelector('.vn').textContent):null;
        }""", sec_title)

    print("服装:", chips_of("服装"))
    print("表情:", chips_of("表情"))
    print("帽子:", chips_of("帽子"))

    # 1) 点「长袍」整套上身
    pg.evaluate("""()=>{
      const secs=[...document.querySelectorAll('.lsec')];
      const s=secs.find(x=>x.querySelector('.ln').textContent==='服装');
      [...s.querySelectorAll('.lchip')].find(c=>c.querySelector('.vn').textContent==='长袍').click();
    }""")
    pg.wait_for_timeout(300)
    parts = pg.evaluate("()=>state.variants")
    print("穿长袍后:", {k: v for k, v in parts.items() if v and k in
          ["body","arm_l","fore_l","shin_l","hat","cape","weapon","face"]})

    # 2) 戴尖帽
    pg.evaluate("""()=>{
      const secs=[...document.querySelectorAll('.lsec')];
      const s=secs.find(x=>x.querySelector('.ln').textContent==='帽子');
      [...s.querySelectorAll('.lchip')].find(c=>c.querySelector('.vn').textContent==='尖帽').click();
    }""")
    pg.wait_for_timeout(300)

    # 3) 换表情微笑
    pg.evaluate("""()=>{
      const secs=[...document.querySelectorAll('.lsec')];
      const s=secs.find(x=>x.querySelector('.ln').textContent==='表情');
      [...s.querySelectorAll('.lchip')].find(c=>c.querySelector('.vn').textContent==='微笑').click();
    }""")
    pg.wait_for_timeout(300)

    # 4) 悬停「皮甲」试穿（不点击，应只影响画布不改 state）
    pg.evaluate("""()=>{
      const secs=[...document.querySelectorAll('.lsec')];
      const s=secs.find(x=>x.querySelector('.ln').textContent==='服装');
      [...s.querySelectorAll('.lchip')].find(c=>c.querySelector('.vn').textContent==='皮甲')
        .dispatchEvent(new MouseEvent('mouseenter'));
    }""")
    pg.wait_for_timeout(200)
    print("悬停皮甲时画布状态:", pg.evaluate("()=>document.getElementById('stat').textContent"))
    pg.evaluate("""()=>{
      const secs=[...document.querySelectorAll('.lsec')];
      const s=secs.find(x=>x.querySelector('.ln').textContent==='服装');
      [...s.querySelectorAll('.lchip')].find(c=>c.querySelector('.vn').textContent==='皮甲')
        .dispatchEvent(new MouseEvent('mouseleave'));
    }""")
    pg.wait_for_timeout(200)
    print("移开后画布状态:", pg.evaluate("()=>document.getElementById('stat').textContent"))

    # 5) 染一块布料色
    pg.evaluate("()=>{ state.color.cloth='#2f8f6a'; onColorChange(); }")
    pg.wait_for_timeout(400)

    pg.screenshot(path=out)
    print("ERRORS:", json.dumps(errs[:10], ensure_ascii=False))
    b.close()
