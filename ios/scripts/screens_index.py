#!/usr/bin/env python3
"""Writes index.html beside the screenshots ios/scripts/screens.sh took: one section per screen, in the app's order
(screens.txt), each device and appearance side by side. Usage: screens_index.py <folder>"""
import html
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
order = [line.split()[0] for line in (out / "screens.txt").read_text().splitlines() if line.strip()]
shots = sorted(p.name for p in out.glob("*.png"))


def screen_of(name):
    # <device>-<appearance>-<screen>.png
    return name[:-4].split("-", 2)[2]


sections = []
for screen in order:
    mine = [s for s in shots if screen_of(s) == screen]
    if not mine:
        sections.append(f'<section><h2>{html.escape(screen)}</h2><p class="none">no screenshot</p></section>')
        continue
    figures = "".join(
        f'<figure><a href="{html.escape(s)}"><img src="{html.escape(s)}" loading="lazy"></a>'
        f'<figcaption>{html.escape(s[:-4].rsplit("-" + screen, 1)[0])}</figcaption></figure>' for s in mine)
    sections.append(f'<section id="{html.escape(screen)}"><h2>{html.escape(screen)}</h2><div class="row">{figures}</div></section>')

links = " · ".join(f'<a href="#{html.escape(s)}">{html.escape(s)}</a>' for s in order)
page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Solstice screens</title>
<style>
body {{ font: 14px -apple-system, system-ui, sans-serif; margin: 16px; background: #f2f2f7; color: #1c1c1e; }}
nav {{ line-height: 1.8; margin-bottom: 16px; }}
section {{ margin: 24px 0; }}
h2 {{ font-size: 17px; margin: 0 0 8px; }}
.row {{ display: flex; gap: 12px; overflow-x: auto; align-items: flex-start; }}
figure {{ margin: 0; flex: none; }}
img {{ height: 420px; border-radius: 8px; box-shadow: 0 1px 4px rgba(0,0,0,.2); display: block; }}
figcaption {{ font-size: 12px; color: #6e6e73; margin-top: 4px; }}
.none {{ color: #c00; }}
</style></head><body>
<h1>Solstice screens</h1>
<nav>{links}</nav>
{''.join(sections)}
</body></html>
"""
(out / "index.html").write_text(page, encoding="utf-8")
print(f"index.html: {len(order)} screens, {len(shots)} screenshots")
