# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
import html
from pathlib import Path
from urllib.parse import quote


def write_index(output, results, label):
    cards = []
    for result in results:
        sheet = Path(result['contact_sheet_path']).relative_to(output).as_posix()
        proxy = Path(result['proxy_path']).relative_to(output).as_posix()
        name = html.escape(result['original']['relative_path'])
        cards.append(f'<article><h2>{name}</h2><a href="{quote(sheet)}"><img loading="lazy" src="{quote(sheet)}" alt="Contact sheet for {name}"></a><p><a href="{quote(proxy)}">Proxy MOV</a> · <a href="{quote(sheet)}">Full contact sheet</a></p></article>')
    title = html.escape(label)
    divisor=results[0].get('proxy_scale_divisor',4) if results else 2
    resolution='Half-resolution' if divisor==2 else 'Quarter-resolution'
    page = f'''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{title} footage</title>
<style>body{{font:16px system-ui,sans-serif;background:#10151d;color:#edf2fa;margin:32px}}main{{display:grid;grid-template-columns:repeat(auto-fit,minmax(340px,1fr));gap:24px}}article{{background:#1c2533;padding:16px;border-radius:12px}}h2{{font-size:15px;overflow-wrap:anywhere}}img{{width:100%;height:auto}}a{{color:#9dc7ff}}p{{line-height:1.6}}</style>
<h1>{title}</h1><p>{len(results)} clips · {resolution}, 10-bit ProRes Proxy MOVs · 12 timestamped frames per contact sheet. Open any sheet to inspect full size.</p>
<p>In Premiere, select original clips in the Project panel, then Proxy → Attach Proxies. Browse to the matching _Proxy.mov files here. Test framing, audio and sync before editing. Originals retain their existing locations.</p>
<main>{''.join(cards)}</main></html>'''
    (output / 'index.html').write_text(page, encoding='utf-8')
