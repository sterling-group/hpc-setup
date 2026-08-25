#!/usr/bin/env python3
"""Documentation hygiene checks that are easy to get wrong by hand.

Three things, each of which has actually gone wrong in this repo:

  continuations - a backslash followed by whitespace at end of line escapes the
                  SPACE, not the newline, so the command silently splits in two.
                  This bit the "Test restores" command in the rclone guide, i.e.
                  the one command you run when you actually need the backup.

  paths         - every scripts/<name> the docs tell you to run must exist. The
                  LaTeX guide told readers to install scripts/cronscript, which
                  has never existed in this repository.

  pdf contents  - \\tableofcontents needs TWO pdflatex passes: the first writes
                  the .toc, the second typesets it. A one-pass build silently
                  produces a PDF with a "Contents" heading and nothing under it.
                  Use guides/build-pdfs.sh, which does both passes.

Usage: tests/check-docs.py
"""
import pathlib
import re
import sys
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = (
    [ROOT / "README.md"]
    + sorted(ROOT.glob("guides/**/*.md"))
    + sorted(ROOT.glob("guides/**/*.tex"))
)
SCRIPTS = sorted(ROOT.glob("scripts/*")) + sorted(ROOT.glob("tests/*"))

problems = []

# --- broken line continuations ----------------------------------------------
for f in DOCS + SCRIPTS:
    if f.is_dir():
        continue
    for i, line in enumerate(f.read_text(errors="replace").splitlines(), 1):
        if re.search(r"\\[ \t]+$", line):
            rel = f.relative_to(ROOT)
            problems.append(f"{rel}:{i}: backslash followed by whitespace - the line does not continue")

# --- documented script paths exist ------------------------------------------
for f in DOCS:
    text = f.read_text(errors="replace")
    for rel_path in sorted(set(re.findall(r"hpc-setup/(scripts/[A-Za-z0-9_.-]+)", text))):
        if not (ROOT / rel_path).exists():
            problems.append(f"{f.relative_to(ROOT)}: references {rel_path}, which does not exist")

# --- every PDF's table of contents is complete ------------------------------
for tex in sorted(ROOT.glob("guides/**/*.tex")):
    pdf = tex.with_suffix(".pdf")
    if not pdf.exists():
        continue
    src = tex.read_text()
    if "\\tableofcontents" not in src:
        continue
    # starred forms are deliberately left out of the contents
    expected = len(re.findall(r"^\s*\\(?:sub)?section\{", src, re.M))

    chunks = []
    for m in re.finditer(rb"stream\r?\n(.*?)endstream", pdf.read_bytes(), re.S):
        try:
            chunks.append(zlib.decompress(m.group(1)))
        except Exception:
            pass
    strings = re.findall(rb"\((?:[^()\\]|\\.)*\)", b"\n".join(chunks))
    text = b" ".join(s[1:-1] for s in strings).decode("latin-1")

    if len(re.findall(r"\.\s?\.\s?\.\s?\.", text)) == 0 and expected:
        problems.append(
            f"{pdf.relative_to(ROOT)}: table of contents is empty "
            f"({expected} sections) - rebuild with guides/build-pdfs.sh (two passes)"
        )

for p in problems:
    print(f"  {p}")
print(f"{len(problems)} problem(s)")
sys.exit(1 if problems else 0)
