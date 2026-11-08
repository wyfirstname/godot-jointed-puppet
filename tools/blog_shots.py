from playwright.sync_api import sync_playwright

URL = "file:///F:/aiprojects/paperdoll-like/tools/character_designer.html"
OUT = "F:/aiprojects/paperdoll-like/docs/blog/"

CLICK = """([secTitle, chipName])=>{
  const secs=[...document.querySelectorAll('.lsec')];
  const s=secs.find(x=>x.querySelector('.ln').textContent===secTitle);
  [...s.querySelectorAll('.lchip')].find(c=>c.querySelector('.vn').textContent===chipName).click();
}"""
HOVER = """([secTitle, chipName, on])=>{
  const secs=[...document.querySelectorAll('.lsec')];
  const s=secs.find(x=>x.querySelector('.ln').textContent===secTitle);
  const el=[...s.querySelectorAll('.lchip')].find(c=>c.querySelector('.vn').textContent===chipName);
  el.dispatchEvent(new MouseEvent(on?'mouseenter':'mouseleave'));
}"""

with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1680, "height": 1000}, device_scale_factor=1)
    pg.goto(URL)
    pg.wait_for_timeout(2600)
    pg.screenshot(path=OUT + "shot_default.png")

    # 霜语法师式：长袍 + 尖帽 + 微笑 + 蓝布
    pg.evaluate(CLICK, ["服装", "长袍"])
    pg.wait_for_timeout(200)
    pg.evaluate(CLICK, ["帽子", "尖帽"])
    pg.evaluate(CLICK, ["表情", "微笑"])
    pg.evaluate("()=>{ state.color.cloth='#2f6fb8'; state.color.metal='#c0c6d0'; onColorChange(); }")
    pg.wait_for_timeout(500)
    pg.screenshot(path=OUT + "shot_mage.png")

    # 悬停"皮甲"：画布已换成皮甲，但选中态还是长袍
    pg.evaluate(HOVER, ["服装", "皮甲", True])
    pg.wait_for_timeout(350)
    pg.screenshot(path=OUT + "shot_hover.png")
    b.close()
print("ok")
