#!/usr/bin/env python3
"""Render a captured terminal log as an HTML "screenshot" (window + colours).

    tools/render-terminal.py LOG OUT.html --title "Terminal" [--theme bash|powershell] [--cmd "./install.sh"]

bash theme: ANSI colour codes in the log are honoured (capture with
`script -qec "cmd" /dev/null > log`). powershell theme: the log has no colour
codes (Write-Host colours are lost when redirected), so lines are coloured the
way install.ps1 prints them ([OK] green, [!] yellow, ==> cyan, ERRO red).
tools/screenshots.sh turns the HTML into PNG with a headless Chrome.
"""
import argparse
import html
import re

ANSI = re.compile(r"\x1b\[([0-9;]*)m")
COLOURS = {"31": "#ff6b6b", "32": "#5af78e", "33": "#f3f99d", "36": "#57c7ff", "37": "#f1f1f0"}


def ansi_to_html(text: str) -> str:
    out, bold, colour, pos = [], False, None, 0

    def span(chunk: str) -> str:
        if not chunk:
            return ""
        style = []
        if colour:
            style.append(f"color:{colour}")
        if bold:
            style.append("font-weight:700")
        esc = html.escape(chunk)
        return f'<span style="{";".join(style)}">{esc}</span>' if style else esc

    for m in ANSI.finditer(text):
        out.append(span(text[pos:m.start()]))
        for code in (m.group(1) or "0").split(";"):
            if code in ("0", ""):
                bold, colour = False, None
            elif code == "1":
                bold = True
            elif code in COLOURS:
                colour = COLOURS[code]
        pos = m.end()
    out.append(span(text[pos:]))
    return "".join(out)


def powershell_to_html(text: str) -> str:
    lines = []
    for line in text.splitlines():
        esc = html.escape(line)
        s = line.strip()
        if s.startswith("[OK]") or s.startswith("Tudo certo") or "instalado com sucesso" in s or s.startswith("====") or "desinstalado" in s:
            esc = f'<span style="color:#5af78e">{esc}</span>'
        elif s.startswith("[!]"):
            esc = f'<span style="color:#f3f99d">{esc}</span>'
        elif s.startswith("==>"):
            esc = f'<span style="color:#57c7ff;font-weight:700">{esc}</span>'
        elif s.startswith("ERRO"):
            esc = f'<span style="color:#ff6b6b;font-weight:700">{esc}</span>'
        lines.append(esc)
    return "\n".join(lines)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("out")
    ap.add_argument("--title", default="Terminal")
    ap.add_argument("--theme", choices=["bash", "powershell"], default="bash")
    ap.add_argument("--cmd", default="")
    ap.add_argument("--prompt", default="", help='prompt shown before --cmd (powershell theme), e.g. "PS C:\\Rekognitor>"')
    a = ap.parse_args()

    raw = open(a.log, encoding="utf-8", errors="replace").read().replace("\r\n", "\n").replace("\r", "")
    body = ansi_to_html(raw) if a.theme == "bash" else powershell_to_html(raw)
    if a.theme == "powershell":
        bg, fg, bar = "#012456", "#eeedf0", "#f3f3f3"
        prompt = f'<span style="color:#eeedf0">{html.escape(a.prompt or "C:\\Rekognitor>")} </span>{html.escape(a.cmd)}\n' if a.cmd else ""
    else:
        bg, fg, bar = "#1e1e2e", "#e6e6e6", "#2d2d3a"
        prompt = f'<span style="color:#5af78e">usuario@maquina</span>:<span style="color:#57c7ff">~/rekognitor-setup</span>$ {html.escape(a.cmd)}\n' if a.cmd else ""
    title_fg = "#333" if a.theme == "powershell" else "#bbb"
    dots = "" if a.theme == "powershell" else (
        '<span class="d" style="background:#ff5f56"></span><span class="d" style="background:#ffbd2e"></span>'
        '<span class="d" style="background:#27c93f"></span>')
    doc = f"""<!doctype html><html><head><meta charset="utf-8"><style>
html,body{{margin:0;background:#e9ecf1;}}
.w{{display:inline-block;margin:24px;border-radius:10px;overflow:hidden;box-shadow:0 12px 32px rgba(0,0,0,.28);min-width:760px}}
.t{{background:{bar};color:{title_fg};font:13px/1 -apple-system,Segoe UI,Helvetica,Arial,sans-serif;padding:10px 14px;display:flex;align-items:center;gap:8px}}
.d{{width:12px;height:12px;border-radius:50%;display:inline-block}}
.t b{{font-weight:500;margin-left:8px}}
pre{{margin:0;background:{bg};color:{fg};font:14px/1.45 "DejaVu Sans Mono",Consolas,Menlo,monospace;padding:16px 20px 20px;white-space:pre}}
</style></head><body><div class="w" id="shot"><div class="t">{dots}<b>{html.escape(a.title)}</b></div><pre>{prompt}{body}</pre></div></body></html>"""
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(doc)
    # window size for the headless-Chrome screenshot (tools/screenshots.sh)
    plain = ANSI.sub("", raw).splitlines() + ([a.cmd + " " * 40] if a.cmd else [])
    width = max(760, int(max(len(l) for l in plain) * 8.45) + 40) + 48
    height = int(len(plain) * 20.3) + 48 + 34 + 36 + 4
    print(f"{width},{height}")


if __name__ == "__main__":
    main()
