#!/usr/bin/env python3
"""Flatten the UE4SS Documentation PDF into a searchable Markdown reference.

The PDF is the docs.ue4ss.com print view: every page carries a date stamp, a
"UE4SS Documentation" running header, a "<n>/<total>" footer and the print URL.
This strips that boilerplate, promotes each page's section title to a heading, and
collapses blank runs. Lists and code blocks lose some of their original formatting
in PDF text extraction; the PDF and docs.ue4ss.com remain authoritative.

Usage: python tools/parse_ue4ss_docs.py [in.pdf] [out.md]
Requires `pdftotext` (poppler) on PATH.
"""
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
IN_PDF = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "UE4SS Documentation.pdf")
OUT_MD = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "G1R", "reference", "UE4SS-Documentation.md")

HDR = "UE4SS Documentation"

# The published docs (PDF + docs.ue4ss.com) predate the game-thread Delayed Action System
# (RE-UE4SS PR #1128) that the build exposes, so we append it to every regen.
SUPPLEMENT = """## Delayed Action System (game-thread timers)

Appended by `tools/parse_ue4ss_docs.py`, not from the source PDF: the published docs predate it.
Sourced from RE-UE4SS PR #1128 and verified live in this build (see
`G1R/UE4SS-Lua-Best-Practices.md`). These run the callback ON the game thread, so they need no
nested `ExecuteInGameThread` and avoid the `LoopAsync` + `ExecuteInGameThread` reentrancy bug
(issue #1180). Per the PR: "Mod creators should avoid using `ExecuteAsync` and `LoopAsync` in
favor of the new system when possible." Route periodic and delayed work through `kit.async`,
which prefers these and falls back to the async variants only where a build lacks them.

ExecuteInGameThreadWithDelay(integer DelayMs, function Callback) -> handle
- Runs Callback once on the game thread after DelayMs. Returns a cancellable handle.
LoopInGameThreadWithDelay(integer DelayMs, function Callback) -> handle
- Runs Callback on the game thread every DelayMs until cancelled. Returns a cancellable handle.
ExecuteInGameThreadAfterFrames(integer Frames, function Callback) -> handle
- Like ExecuteInGameThreadWithDelay but the delay is counted in rendered frames.
LoopInGameThreadAfterFrames(integer Frames, function Callback) -> handle
- Like LoopInGameThreadWithDelay but the interval is counted in frames.
RetriggerableExecuteInGameThreadWithDelay(handle Handle, integer DelayMs, function Callback)
- Re-arms an existing delayed action, mirroring UE's Delay node (a fresh call resets the timer).
CancelDelayedAction(handle Handle)
- Cancels a pending delayed action by its handle (only one created by the same mod).

The system also exposes pause / unpause / query operations on a handle (per PR #1128); confirm
their exact names against the RE-UE4SS source before relying on them, they are not used here.

"""

date_re = re.compile(r"^\d{2}\.\d{2}\.\d{2},\s*\d{2}:\d{2}$")
url_re = re.compile(r"^https://docs\.ue4ss\.com/print\.html$")
pg_re = re.compile(r"^\d+\s*/\s*\d+$")


def is_boiler(line):
    s = line.strip()
    return (not s) or bool(date_re.match(s)) or bool(url_re.match(s)) or bool(pg_re.match(s)) or s == HDR


def is_title(s):
    # A real section title is a short, heading-like line; a mid-sentence page-break
    # fragment is not. Reject fragments so they stay in the body instead of becoming
    # a bogus heading.
    s = s.strip()
    if not (1 <= len(s) <= 55):
        return False
    if s[-1] in ".,);:":
        return False
    if "http" in s:
        return False
    if not any(c.isalpha() for c in s):
        return False
    return s[0].isupper() or s[0] == "_"


def main():
    with tempfile.NamedTemporaryFile(suffix=".txt", delete=False) as tmp:
        txt_path = tmp.name
    try:
        subprocess.run(["pdftotext", "-enc", "UTF-8", IN_PDF, txt_path], check=True)
        raw = open(txt_path, encoding="utf-8").read()
    finally:
        os.unlink(txt_path)

    out, seen = [], set()
    for pi, page in enumerate(raw.split("\f")):
        lines = page.splitlines()
        if not any(l.strip() for l in lines):
            continue
        hdr_idx = next((i for i, l in enumerate(lines) if l.strip() == HDR), None)
        # promote a heading only when the single line before the running header looks
        # like a real title (not a wrapped-sentence fragment)
        title = ""
        if pi > 0 and hdr_idx is not None:
            pre = [l.strip() for l in lines[:hdr_idx] if l.strip() and not date_re.match(l.strip())]
            if len(pre) == 1 and is_title(pre[0]):
                title = pre[0]
        if title and title not in seen:
            seen.add(title)
            out += ["", "## " + title, ""]
        # body = every non-boilerplate line, minus the one we promoted (no duplicate)
        skipped = False
        for l in lines:
            if is_boiler(l):
                out.append("")
            elif title and not skipped and l.strip() == title:
                skipped = True
            else:
                out.append(l.rstrip())

    text = re.sub(r"\n{3,}", "\n\n", "\n".join(out)).strip() + "\n"
    header = (
        "# UE4SS Documentation (parsed reference)\n\n"
        "Auto-extracted from `tools/UE4SS Documentation.pdf` (docs.ue4ss.com, print view), then\n"
        "supplemented below. Flat, searchable copy; the PDF and docs.ue4ss.com are authoritative for\n"
        "what they cover, but BOTH lag the running build. Regenerate with\n"
        "`python tools/parse_ue4ss_docs.py` after updating the PDF.\n\n"
        "The published docs predate the game-thread Delayed Action System (RE-UE4SS PR #1128) that\n"
        "this build exposes and the repo uses (`kit.async`), so this script appends it as a supplement\n"
        "(the \"Delayed Action System\" section below). Confirm any newest API against the RE-UE4SS\n"
        "source and PRs, not only this copy. Lists and code blocks lose some formatting in extraction.\n\n---\n\n"
    )
    if "## Global Functions" in text:
        text = text.replace("## Global Functions", SUPPLEMENT + "## Global Functions", 1)
    else:
        text = text + "\n" + SUPPLEMENT
    os.makedirs(os.path.dirname(OUT_MD), exist_ok=True)
    open(OUT_MD, "w", encoding="utf-8", newline="\n").write(header + text)
    print("wrote", OUT_MD, os.path.getsize(OUT_MD), "bytes,", text.count("\n## "), "headings")


if __name__ == "__main__":
    main()
